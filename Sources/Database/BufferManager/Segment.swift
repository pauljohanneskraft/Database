/// Base class for buffer-managed segments. `BTree`, `SPSegment`, etc.
/// inherit to pick up the segment id and the buffer manager reference.
public class Segment {
    public let segmentId: UInt16
    public let bufferManager: BufferManager

    public init(segmentId: UInt16, bufferManager: BufferManager) {
        self.segmentId = segmentId
        self.bufferManager = bufferManager
    }
}
