/// Slotted page laid out directly on a `BufferFrame`'s bytes.
///
/// Layout (page_size = N bytes):
///   `[0:12)`            Header
///   `[12:12+slotCount*8)` Slot table (8 bytes per slot, grows up)
///   `[dataStart:N)`     Record data (grows down)
///
/// The `SlottedPage` struct is a thin view over the buffer pointer — there is
/// no Swift heap allocation. Instances must not outlive the underlying frame.
public struct SlottedPage {
    /// Header is 2 + 2 + 4 + 4 = 12 bytes, naturally aligned, no trailing
    /// padding. Verified against `slottedPageRelocateWithCompactification`
    /// which asserts `freeSpace == 20` for `1024 - 62*16 - 12`.
    public static let headerSize: Int = 12
    public static let slotSize: Int = 8

    /// Header field byte offsets within the page.
    private static let slotCountOffset: Int = 0
    private static let firstFreeSlotOffset: Int = 2
    private static let dataStartOffset: Int = 4
    private static let freeSpaceOffset: Int = 8

    public let buffer: UnsafeMutableRawPointer

    public init(buffer: UnsafeMutableRawPointer) {
        self.buffer = buffer
    }

    // MARK: - Header field accessors

    public var slotCount: UInt16 {
        get { buffer.load(fromByteOffset: Self.slotCountOffset, as: UInt16.self) }
        set { buffer.storeBytes(of: newValue, toByteOffset: Self.slotCountOffset, as: UInt16.self) }
    }

    public var firstFreeSlot: UInt16 {
        get { buffer.load(fromByteOffset: Self.firstFreeSlotOffset, as: UInt16.self) }
        set { buffer.storeBytes(of: newValue, toByteOffset: Self.firstFreeSlotOffset, as: UInt16.self) }
    }

    public var dataStart: UInt32 {
        get { buffer.load(fromByteOffset: Self.dataStartOffset, as: UInt32.self) }
        set { buffer.storeBytes(of: newValue, toByteOffset: Self.dataStartOffset, as: UInt32.self) }
    }

    public var freeSpace: UInt32 {
        get { buffer.load(fromByteOffset: Self.freeSpaceOffset, as: UInt32.self) }
        set { buffer.storeBytes(of: newValue, toByteOffset: Self.freeSpaceOffset, as: UInt32.self) }
    }

    // MARK: - Initialization

    /// Zeros the buffer and writes the initial header.
    public static func initialize(buffer: UnsafeMutableRawPointer, pageSize: Int) {
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: pageSize)
        var page = SlottedPage(buffer: buffer)
        page.slotCount = 0
        page.firstFreeSlot = 0
        page.dataStart = UInt32(pageSize)
        page.freeSpace = UInt32(pageSize - headerSize)
    }

    // MARK: - Slot access

    /// Loads slot at `index`. Slot table starts immediately after the header
    /// at byte offset 12, so the UInt64 read is not 8-byte aligned — use
    /// `loadUnaligned` instead of `load`.
    public func slot(at index: UInt16) -> Slot {
        let offset = Self.headerSize + Int(index) * Self.slotSize
        return Slot(rawValue: buffer.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    /// Stores slot at `index`. See `slot(at:)` for why we go through
    /// `copyMemory` rather than `storeBytes`.
    public func setSlot(_ slot: Slot, at index: UInt16) {
        let offset = Self.headerSize + Int(index) * Self.slotSize
        var v = slot.rawValue
        withUnsafeBytes(of: &v) { src in
            if let s = src.baseAddress {
                buffer.advanced(by: offset).copyMemory(from: s, byteCount: Self.slotSize)
            }
        }
    }

    /// Compacted free space (what would be available after `compactify`).
    public func getFreeSpace() -> UInt32 {
        freeSpace
    }

    /// Free space without compactification — gap between the slot table and
    /// the data region.
    public func getFragmentedFreeSpace() -> UInt32 {
        dataStart - UInt32(Self.headerSize) - UInt32(slotCount) * UInt32(Self.slotSize)
    }

    // MARK: - Allocation

    /// Allocates a slot for `dataSize` bytes. Returns the slot index.
    /// Throws if the page does not have room.
    @discardableResult
    public mutating func allocate(dataSize: UInt32, pageSize: Int) throws -> UInt16 {
        if (UInt64(dataSize) + UInt64(Self.slotSize)) > UInt64(getFreeSpace()) {
            throw SlottedPageError.outOfSpace
        }

        if getFragmentedFreeSpace() < dataSize + UInt32(Self.slotSize) {
            compactify(pageSize: pageSize)
        }

        // Reuse a hole in the existing slot table.
        var index = firstFreeSlot
        while index < slotCount {
            let s = slot(at: index)
            if !s.isEmpty {
                index &+= 1
                continue
            }

            dataStart &-= dataSize
            freeSpace &-= dataSize

            var newSlot = Slot()
            newSlot.setSlot(offset: dataStart, size: dataSize, isRedirectTarget: false)
            setSlot(newSlot, at: index)

            // If we used the slot pointed at by first_free_slot, advance it.
            if index == firstFreeSlot {
                var freeIndex = firstFreeSlot &+ 1
                while freeIndex < slotCount {
                    if slot(at: freeIndex).isEmpty {
                        firstFreeSlot = freeIndex
                        return index
                    }
                    freeIndex &+= 1
                }
                firstFreeSlot = slotCount
            }
            return index
        }

        // No hole available — append a new slot at the end of the table.
        let newIndex = slotCount
        slotCount &+= 1
        firstFreeSlot = slotCount
        dataStart &-= dataSize
        var newSlot = Slot()
        newSlot.setSlot(offset: dataStart, size: dataSize, isRedirectTarget: false)
        setSlot(newSlot, at: newIndex)
        freeSpace &-= dataSize + UInt32(Self.slotSize)
        return newIndex
    }

    // MARK: - Relocation

    /// Resizes the record at `slotId` to `dataSize`. The slot's
    /// `redirect_target` flag is preserved. If the slot currently holds a
    /// redirect TID, it is replaced with an in-page record.
    public mutating func relocate(slotId: UInt16, dataSize: UInt32, pageSize: Int) {
        var s = slot(at: slotId)
        let dataSizeBefore: UInt32 = s.isRedirect ? 0 : s.size
        let previousEnd: UInt32 = slotId == 0 ? UInt32(pageSize) : slot(at: slotId - 1).offset

        if !s.isRedirect && (dataSizeBefore > dataSize || previousEnd >= s.offset + dataSize) {
            freeSpace &+= dataSizeBefore
            s.setSlot(offset: s.offset, size: dataSize, isRedirectTarget: s.isRedirectTarget)
            setSlot(s, at: slotId)
            freeSpace &-= dataSize
            return
        }

        let isRedirect = s.isRedirect
        let copySize = min(dataSizeBefore, dataSize)
        var copyData = [UInt8](repeating: 0, count: Int(copySize))
        if !isRedirect && copySize > 0 {
            copyData.withUnsafeMutableBytes { dst in
                if let d = dst.baseAddress {
                    d.copyMemory(from: buffer.advanced(by: Int(s.offset)), byteCount: Int(copySize))
                }
            }
        }

        freeSpace &+= s.size

        if getFragmentedFreeSpace() < dataSize {
            // Temporarily mark the slot as a redirect so compactify skips it.
            // `TID(1, 1)` is an arbitrary non-zero placeholder — it never
            // leaves this scope, the slot is overwritten with the real layout
            // immediately after.
            var tmp = s
            tmp.setRedirectTID(TID(pageId: 1, slot: 1))
            setSlot(tmp, at: slotId)
            compactify(pageSize: pageSize)
            // Reload after compactify (the slot table itself is unchanged here
            // since we only marked this slot, but pull a fresh copy to keep
            // the next `setSlot` call self-contained).
            s = slot(at: slotId)
        }

        dataStart &-= dataSize
        s.setSlot(offset: dataStart, size: dataSize, isRedirectTarget: s.isRedirectTarget)
        setSlot(s, at: slotId)
        if !isRedirect && copySize > 0 {
            copyData.withUnsafeBytes { src in
                if let s = src.baseAddress {
                    buffer.advanced(by: Int(dataStart)).copyMemory(from: s, byteCount: Int(copySize))
                }
            }
        }
        freeSpace &-= dataSize
    }

    // MARK: - Erase

    /// Erases the slot at `slotId`. Trims trailing empty slots from the slot
    /// table.
    public mutating func erase(slotId: UInt16) {
        let s = slot(at: slotId)
        freeSpace &+= s.size

        if s.offset == dataStart {
            dataStart &+= s.size
        }

        var cleared = s
        cleared.clear()
        setSlot(cleared, at: slotId)

        while slotCount > 0 && slot(at: slotCount - 1).isEmpty {
            slotCount &-= 1
            freeSpace &+= UInt32(Self.slotSize)
        }

        firstFreeSlot = min(firstFreeSlot, slotId)
    }

    // MARK: - Compactify

    /// Compacts the data region, eliminating gaps left by erased / shrunk
    /// slots. Preserves redirect-target flags on each slot. Skips empty and
    /// redirect slots.
    public mutating func compactify(pageSize: Int) {
        if getFragmentedFreeSpace() >= freeSpace { return }

        // Snapshot the page so we can copy record data back in one direction.
        var previousPage = [UInt8](repeating: 0, count: pageSize)
        previousPage.withUnsafeMutableBytes { dst in
            if let d = dst.baseAddress {
                d.copyMemory(from: buffer, byteCount: pageSize)
            }
        }

        freeSpace = UInt32(pageSize - Self.headerSize)
        var dataOffset = UInt32(pageSize)

        for index: UInt16 in 0..<slotCount {
            var s = slot(at: index)
            if s.isEmpty || s.isRedirect {
                freeSpace &-= UInt32(Self.slotSize)
                continue
            }

            dataOffset &-= s.size

            previousPage.withUnsafeBytes { src in
                if let p = src.baseAddress {
                    buffer.advanced(by: Int(dataOffset))
                        .copyMemory(from: p.advanced(by: Int(s.offset)), byteCount: Int(s.size))
                }
            }
            s.setSlot(offset: dataOffset, size: s.size, isRedirectTarget: s.isRedirectTarget)
            setSlot(s, at: index)
            freeSpace &-= s.size + UInt32(Self.slotSize)
        }

        dataStart = dataOffset
    }
}

// MARK: - Slot

extension SlottedPage {
    /// 64-bit slot. Bit layout:
    ///
    /// - `[0:24)`  size       (3 bytes)
    /// - `[24:48)` offset     (3 bytes)
    /// - `[48:56)` `0xFF` if this slot is a redirect *target*, else `0x00`
    /// - `[56:64)` `0xFF` for normal in-page records; any other value means
    ///             the entire 64-bit value is a redirect TID, not a packed
    ///             offset/size record.
    public struct Slot: Hashable, Sendable {
        public var rawValue: UInt64

        public init(rawValue: UInt64 = 0) {
            self.rawValue = rawValue
        }

        public var isEmpty: Bool { rawValue == 0 }
        public var isRedirect: Bool { (rawValue >> 56) != 0xFF }
        public var isRedirectTarget: Bool { ((rawValue >> 48) & 0xFF) != 0 }

        public var size: UInt32 { UInt32(rawValue & 0xFFFFFF) }
        public var offset: UInt32 { UInt32((rawValue >> 24) & 0xFFFFFF) }

        /// Reinterpret the slot as a redirect TID. Only meaningful if
        /// `isRedirect` is true.
        public var asRedirectTID: TID { TID(rawValue: rawValue) }

        public mutating func clear() { rawValue = 0 }

        public mutating func setSlot(offset: UInt32, size: UInt32, isRedirectTarget: Bool) {
            var v: UInt64 = 0
            v ^= UInt64(size & 0xFFFFFF)
            v ^= UInt64(offset & 0xFFFFFF) << 24
            v ^= (isRedirectTarget ? UInt64(0xFF) : 0) << 48
            v ^= UInt64(0xFF) << 56
            rawValue = v
        }

        public mutating func setRedirectTID(_ tid: TID) {
            // The high byte of a redirect TID must be < 0xFF; otherwise the
            // raw bit pattern would alias an in-page record entry.
            precondition((0xFF - (tid.rawValue >> 56)) > 0, "invalid redirect TID")
            rawValue = tid.rawValue
        }

        public mutating func markAsRedirectTarget(_ redirect: Bool = true) {
            rawValue &= ~(UInt64(0xFF) << 48)
            if redirect {
                rawValue ^= UInt64(0xFF) << 48
            }
        }
    }
}

public enum SlottedPageError: Error, Equatable, Sendable {
    case outOfSpace
}
