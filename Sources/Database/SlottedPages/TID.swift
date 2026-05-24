/// Tuple identifier — a 64-bit value that locates a record within a segment.
///
/// Bit layout:
///   `[0:16)`  slot index within the slotted page
///   `[16:64)` page id within the buffer manager (the upper 16 bits of which
///             encode the segment id, leaving 32 bits of segment-local page id)
///
/// To reconstruct the absolute page id given the segment id, we XOR the
/// segment id back in at bit 48 — `pageId(segmentId:)`.
public struct TID: Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public init(pageId: UInt64, slot: UInt16) {
        self.rawValue = (pageId << 16) ^ UInt64(slot)
    }

    public func pageId(segmentId: UInt16) -> UInt64 {
        (rawValue >> 16) ^ (UInt64(segmentId) << 48)
    }

    public var slot: UInt16 {
        UInt16(rawValue & 0xFFFF)
    }
}
