/// Free-space inventory. One nibble per page — the upper nibble of byte
/// `index` describes page `2*index` and the lower describes page `2*index+1`.
///
/// Encoding: `0xF - free / (page_size / 16)`. Lower encoded value → more free
/// space. `find` walks the FSI pages of this segment looking for the first
/// nibble that fits the required space (strictly better, via the
/// `encodedRequiredSpace - 1` adjustment in `find`).
public final class FSISegment: Segment {
    public let table: SchemaTable

    public init(segmentId: UInt16, bufferManager: BufferManager, table: SchemaTable) {
        self.table = table
        super.init(segmentId: segmentId, bufferManager: bufferManager)
    }

    public func encodeFreeSpace(_ freeSpace: UInt32) -> UInt8 {
        let factor = UInt32(bufferManager.pageSize) / 0x10
        let q = Swift.min(UInt32(0xF), freeSpace / factor)
        return 0xF - UInt8(q)
    }

    public func decodeFreeSpace(_ freeSpace: UInt8) -> UInt32 {
        let factor = UInt32(bufferManager.pageSize) / 0x10
        return UInt32(0xF - freeSpace) * factor
    }

    public func update(targetPage: UInt64, freeSpace: UInt32) throws {
        let pageSize = UInt64(bufferManager.pageSize)
        let segmentPageId = BufferManager.segmentPageId(of: targetPage) / 2
        let pageId = BufferManager.pageId(segmentId: segmentId, segmentPageId: segmentPageId / pageSize)

        let frame = try bufferManager.fixPage(pageId: pageId, exclusive: true)
        let index = Int(segmentPageId % pageSize)
        let encoded = encodeFreeSpace(freeSpace)
        let previous = frame.data.load(fromByteOffset: index, as: UInt8.self)

        let value: UInt8
        if targetPage % 2 == 0 {
            value = (previous & 0x0F) | (encoded << 4)
        } else {
            value = (previous & 0xF0) | (encoded << 0)
        }
        frame.data.storeBytes(of: value, toByteOffset: index, as: UInt8.self)

        bufferManager.unfixPage(frame, isDirty: true)
    }

    public func find(requiredSpace: UInt32) throws -> UInt64? {
        let pageSize = bufferManager.pageSize
        var encodedRequired = encodeFreeSpace(requiredSpace)
        if encodedRequired > 0 {
            encodedRequired -= 1
        }

        // The loop is unbounded but always terminates: a freshly fixed FSI
        // page is zero-initialised, so its first nibble is `0` and
        // `0 <= encodedRequired` always holds. The walk therefore never
        // advances past the last *written* FSI page.
        var segmentPageId: UInt64 = 0
        while true {
            let pageId = BufferManager.pageId(segmentId: segmentId, segmentPageId: segmentPageId)
            let frame = try bufferManager.fixPage(pageId: pageId, exclusive: false)

            for index in 0..<pageSize {
                let value = frame.data.load(fromByteOffset: index, as: UInt8.self)
                let firstValue = (value & 0xF0) >> 4
                let secondValue = (value & 0x0F) >> 0

                if firstValue <= encodedRequired {
                    bufferManager.unfixPage(frame, isDirty: false)
                    return (segmentPageId * UInt64(pageSize) + UInt64(index)) * 2
                }
                if secondValue <= encodedRequired {
                    bufferManager.unfixPage(frame, isDirty: false)
                    return (segmentPageId * UInt64(pageSize) + UInt64(index)) * 2 + 1
                }
            }

            bufferManager.unfixPage(frame, isDirty: false)
            segmentPageId += 1
        }

        return nil
    }
}
