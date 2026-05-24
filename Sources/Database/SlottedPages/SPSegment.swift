/// Slotted-page segment. Allocates records, reads/writes them through
/// `TID`s, and supports resize via at most one level of redirect.
public final class SPSegment: Segment {
    public let schemaSegment: SchemaSegment
    public let fsi: FSISegment
    public let table: SchemaTable

    public init(
        segmentId: UInt16,
        bufferManager: BufferManager,
        schema: SchemaSegment,
        fsi: FSISegment,
        table: SchemaTable
    ) {
        self.schemaSegment = schema
        self.fsi = fsi
        self.table = table
        super.init(segmentId: segmentId, bufferManager: bufferManager)
    }

    /// Allocate a record of `size` bytes. Returns a TID. Throws if the FSI
    /// could not find a page (which the in-memory buffer manager makes
    /// effectively impossible — pages are conjured on demand).
    @discardableResult
    public func allocate(size: UInt32) throws -> TID {
        guard let segmentPageId = try fsi.find(requiredSpace: size + UInt32(SlottedPage.slotSize)) else {
            throw SPSegmentError.noFreePage
        }

        let pageSize = bufferManager.pageSize
        let pageId = BufferManager.pageId(segmentId: segmentId, segmentPageId: segmentPageId)
        let frame = try bufferManager.fixPage(pageId: pageId, exclusive: true)

        var page = SlottedPage(buffer: frame.data)
        // Lazy initialisation marker: a freshly created (zero-init) page has
        // `dataStart == 0`. Real initialised pages always have `dataStart >=
        // headerSize`.
        if page.dataStart == 0 {
            SlottedPage.initialize(buffer: frame.data, pageSize: pageSize)
            page = SlottedPage(buffer: frame.data)
        }

        let slotId = try page.allocate(dataSize: size, pageSize: pageSize)
        try fsi.update(targetPage: segmentPageId, freeSpace: page.getFreeSpace())
        bufferManager.unfixPage(frame, isDirty: true)

        // Track the high-water mark for full-table scans. The schema-segment
        // write on close persists this so `Database.open` can re-establish
        // the bound.
        if segmentPageId + 1 > table.allocatedPages {
            table.allocatedPages = segmentPageId + 1
        }

        return TID(pageId: segmentPageId, slot: slotId)
    }

    /// Enumerate every live record in this segment. Walks
    /// `[0, table.allocatedPages)`, fixing each page shared and emitting a
    /// TID for every non-empty, non-redirect slot. Redirect targets are
    /// reachable via their own pages' `isRedirectTarget` slots and are
    /// included; bare redirect slots (that point elsewhere) are skipped to
    /// avoid double-counting.
    public func allTIDs() throws -> [TID] {
        var out: [TID] = []
        for segPid in 0..<table.allocatedPages {
            let pageId = BufferManager.pageId(segmentId: segmentId, segmentPageId: segPid)
            let frame = try bufferManager.fixPage(pageId: pageId, exclusive: false)
            let page = SlottedPage(buffer: frame.data)
            if page.dataStart == 0 {
                // Page never initialised; skip.
                bufferManager.unfixPage(frame, isDirty: false)
                continue
            }
            let count = Int(page.slotCount)
            for slotIdx in 0..<count {
                let s = page.slot(at: UInt16(slotIdx))
                if s.isEmpty { continue }
                if s.isRedirect { continue }
                out.append(TID(pageId: segPid, slot: UInt16(slotIdx)))
            }
            bufferManager.unfixPage(frame, isDirty: false)
        }
        return out
    }

    /// Read up to `capacity` bytes of the record at `tid` into `record`.
    /// Returns the number of bytes read. Follows a redirect (one hop).
    @discardableResult
    public func read(tid: TID, into record: UnsafeMutableRawPointer, capacity: UInt32) throws -> UInt32 {
        let pageId = tid.pageId(segmentId: segmentId)
        let frame = try bufferManager.fixPage(pageId: pageId, exclusive: false)
        let page = SlottedPage(buffer: frame.data)
        let slot = page.slot(at: tid.slot)

        if slot.isEmpty {
            bufferManager.unfixPage(frame, isDirty: false)
            throw SPSegmentError.emptySlot
        }

        if slot.isRedirect {
            let redirect = slot.asRedirectTID
            bufferManager.unfixPage(frame, isDirty: false)
            return try read(tid: redirect, into: record, capacity: capacity)
        }

        let size = Swift.min(capacity, slot.size)
        record.copyMemory(from: frame.data.advanced(by: Int(slot.offset)), byteCount: Int(size))
        bufferManager.unfixPage(frame, isDirty: false)
        return size
    }

    /// Write up to `recordSize` bytes from `record` into the record at `tid`.
    /// Returns the number of bytes written. Follows a redirect (one hop).
    @discardableResult
    public func write(tid: TID, from record: UnsafeRawPointer, recordSize: UInt32) throws -> UInt32 {
        let pageId = tid.pageId(segmentId: segmentId)
        let frame = try bufferManager.fixPage(pageId: pageId, exclusive: true)
        let page = SlottedPage(buffer: frame.data)
        let slot = page.slot(at: tid.slot)

        if slot.isEmpty {
            bufferManager.unfixPage(frame, isDirty: false)
            throw SPSegmentError.emptySlot
        }

        if slot.isRedirect {
            let redirect = slot.asRedirectTID
            // The first frame did not change, so unfix non-dirty.
            bufferManager.unfixPage(frame, isDirty: false)
            return try write(tid: redirect, from: record, recordSize: recordSize)
        }

        let writeSize = Swift.min(slot.size, recordSize)
        frame.data.advanced(by: Int(slot.offset)).copyMemory(from: record, byteCount: Int(writeSize))
        bufferManager.unfixPage(frame, isDirty: true)
        return writeSize
    }

    /// Resize the record at `tid` to `newLength`. Four cases:
    ///   1. The slot is in-page and the new size still fits → relocate in
    ///      place.
    ///   2. The slot already redirects to a target with room → relocate the
    ///      target.
    ///   3. The slot redirects to a full target → allocate a fresh record,
    ///      copy the data, redirect to it, and erase the old target.
    ///   4. The slot is in-page but won't fit → allocate a fresh record on
    ///      another page, copy the data, and replace the in-page slot with
    ///      a redirect TID.
    public func resize(tid: TID, newLength: UInt32) throws {
        let pageSize = bufferManager.pageSize
        let firstPageId = tid.pageId(segmentId: segmentId)
        let firstFrame = try bufferManager.fixPage(pageId: firstPageId, exclusive: true)
        var firstPage = SlottedPage(buffer: firstFrame.data)
        let firstSlot = firstPage.slot(at: tid.slot)
        let firstSlotSize: UInt32 = firstSlot.isRedirect ? 0 : firstSlot.size

        if !firstSlot.isRedirect &&
            (newLength <= firstSlotSize || (newLength - firstSlotSize) <= firstPage.getFreeSpace()) {
            firstPage.relocate(slotId: tid.slot, dataSize: newLength, pageSize: pageSize)
            try fsi.update(targetPage: BufferManager.segmentPageId(of: firstPageId), freeSpace: firstPage.getFreeSpace())
            bufferManager.unfixPage(firstFrame, isDirty: true)
            return
        }

        if firstSlot.isRedirect {
            let redirectTID = firstSlot.asRedirectTID
            let secondPageId = redirectTID.pageId(segmentId: segmentId)
            let secondFrame = try bufferManager.fixPage(pageId: secondPageId, exclusive: true)
            var secondPage = SlottedPage(buffer: secondFrame.data)
            let secondSlot = secondPage.slot(at: redirectTID.slot)

            if newLength <= secondSlot.size || (newLength - secondSlot.size) <= secondPage.getFreeSpace() {
                secondPage.relocate(slotId: redirectTID.slot, dataSize: newLength, pageSize: pageSize)
                bufferManager.unfixPage(firstFrame, isDirty: false)
                try fsi.update(targetPage: BufferManager.segmentPageId(of: secondPageId), freeSpace: secondPage.getFreeSpace())
                bufferManager.unfixPage(secondFrame, isDirty: true)
                return
            } else {
                // No room on the redirect target → allocate a fresh record,
                // copy, swap the redirect, then erase the old target.
                let newTID = try allocate(size: newLength)
                let thirdPageId = newTID.pageId(segmentId: segmentId)
                let thirdFrame = try bufferManager.fixPage(pageId: thirdPageId, exclusive: true)
                let thirdPage = SlottedPage(buffer: thirdFrame.data)
                var thirdSlot = thirdPage.slot(at: newTID.slot)
                thirdSlot.markAsRedirectTarget()
                thirdPage.setSlot(thirdSlot, at: newTID.slot)

                let copySize = Swift.min(secondSlot.size, newLength)
                if copySize > 0 {
                    thirdFrame.data.advanced(by: Int(thirdSlot.offset))
                        .copyMemory(from: secondFrame.data.advanced(by: Int(secondSlot.offset)), byteCount: Int(copySize))
                }

                var redirectingSlot = firstSlot
                redirectingSlot.setRedirectTID(newTID)
                firstPage.setSlot(redirectingSlot, at: tid.slot)

                try fsi.update(targetPage: BufferManager.segmentPageId(of: firstPageId), freeSpace: firstPage.getFreeSpace())
                bufferManager.unfixPage(firstFrame, isDirty: true)
                bufferManager.unfixPage(secondFrame, isDirty: false)
                try fsi.update(targetPage: BufferManager.segmentPageId(of: thirdPageId), freeSpace: thirdPage.getFreeSpace())
                bufferManager.unfixPage(thirdFrame, isDirty: true)

                try erase(tid: redirectTID)
                return
            }
        }

        // In-page slot too big to keep here → allocate elsewhere, redirect.
        let newTID = try allocate(size: newLength)
        let secondPageId = newTID.pageId(segmentId: segmentId)
        let secondFrame = try bufferManager.fixPage(pageId: secondPageId, exclusive: true)
        let secondPage = SlottedPage(buffer: secondFrame.data)
        var secondSlot = secondPage.slot(at: newTID.slot)

        let copySize = Swift.min(firstSlot.size, newLength)
        if copySize > 0 {
            secondFrame.data.advanced(by: Int(secondSlot.offset))
                .copyMemory(from: firstFrame.data.advanced(by: Int(firstSlot.offset)), byteCount: Int(copySize))
        }
        secondSlot.markAsRedirectTarget()
        secondPage.setSlot(secondSlot, at: newTID.slot)

        // Free the slot's data on the first page (we lose the slot-table
        // entry's-worth of free space because the slot itself stays around as
        // a redirect).
        firstPage.freeSpace = firstPage.freeSpace + firstSlot.size
        if firstSlot.offset == firstPage.dataStart {
            firstPage.dataStart = firstPage.dataStart + firstSlot.size
        }

        var redirectingSlot = firstSlot
        redirectingSlot.setRedirectTID(newTID)
        firstPage.setSlot(redirectingSlot, at: tid.slot)

        try fsi.update(targetPage: BufferManager.segmentPageId(of: firstPageId), freeSpace: firstPage.getFreeSpace())
        bufferManager.unfixPage(firstFrame, isDirty: true)
        try fsi.update(targetPage: BufferManager.segmentPageId(of: secondPageId), freeSpace: secondPage.getFreeSpace())
        bufferManager.unfixPage(secondFrame, isDirty: true)
    }

    /// Erase the record at `tid`. Recurses into the redirect target before
    /// clearing the first slot so the target is released first.
    public func erase(tid: TID) throws {
        let pageId = tid.pageId(segmentId: segmentId)
        let frame = try bufferManager.fixPage(pageId: pageId, exclusive: true)
        var page = SlottedPage(buffer: frame.data)
        let slot = page.slot(at: tid.slot)

        if slot.isRedirect {
            try erase(tid: slot.asRedirectTID)
        }

        page.erase(slotId: tid.slot)
        try fsi.update(targetPage: BufferManager.segmentPageId(of: pageId), freeSpace: page.getFreeSpace())
        bufferManager.unfixPage(frame, isDirty: true)
    }
}

public enum SPSegmentError: Error, Equatable, Sendable {
    case noFreePage
    case emptySlot
}
