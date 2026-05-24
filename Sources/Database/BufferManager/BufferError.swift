/// Errors thrown by `BufferManager`.
public enum BufferError: Error, Equatable {
    /// Thrown by `fixPage` when the buffer is at capacity and every frame is
    /// currently fixed by some caller.
    case bufferFull
}
