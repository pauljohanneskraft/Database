public enum FileMode: Sendable {
    case read
    case write
}

public enum FileError: Error, Equatable {
    case readOnly
    case outOfBounds
    case io(String)
}

/// Block-wise file abstraction.
///
/// `readBlock` and `writeBlock` are required to be safe for concurrent calls
/// against each other; `resize` is not. Implementations may read/write zero
/// bytes at any in-range offset (including `offset == size`).
public protocol File: AnyObject {
    var mode: FileMode { get }
    var size: Int { get }

    /// Resizes the file. Truncates if `newSize < size`, zero-fills if larger.
    /// Must not be used on a `.read` file.
    func resize(_ newSize: Int) throws

    /// Reads `size` bytes starting at `offset` into `buffer`.
    /// `offset + size` must not exceed `size`.
    func readBlock(offset: Int, size: Int, into buffer: UnsafeMutableRawPointer) throws

    /// Writes `size` bytes from `buffer` starting at `offset`.
    /// `offset + size` must not exceed the file's `size` — call `resize` first.
    /// Must not be used on a `.read` file.
    func writeBlock(_ buffer: UnsafeRawPointer, offset: Int, size: Int) throws
}

public extension File {
    func readBlock(offset: Int, size: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: size)
        try bytes.withUnsafeMutableBytes { buf in
            if let base = buf.baseAddress {
                try readBlock(offset: offset, size: size, into: base)
            }
        }
        return bytes
    }
}

/// In-memory File backed by `[UInt8]`. Suited for tests and small inputs.
public final class MemoryFile: File, @unchecked Sendable {
    public private(set) var mode: FileMode
    public var contents: [UInt8]

    public init(mode: FileMode = .write) {
        self.mode = mode
        self.contents = []
    }

    public init(contents: [UInt8], mode: FileMode = .read) {
        self.mode = mode
        self.contents = contents
    }

    public var size: Int { contents.count }

    public func resize(_ newSize: Int) throws {
        guard mode == .write else { throw FileError.readOnly }
        if newSize > contents.count {
            contents.append(contentsOf: repeatElement(0, count: newSize - contents.count))
        } else if newSize < contents.count {
            contents.removeLast(contents.count - newSize)
        }
    }

    public func readBlock(offset: Int, size: Int, into buffer: UnsafeMutableRawPointer) throws {
        guard offset >= 0, size >= 0, offset + size <= contents.count else {
            throw FileError.outOfBounds
        }
        if size == 0 { return }
        contents.withUnsafeBytes { src in
            buffer.copyMemory(from: src.baseAddress!.advanced(by: offset), byteCount: size)
        }
    }

    public func writeBlock(_ buffer: UnsafeRawPointer, offset: Int, size: Int) throws {
        guard mode == .write else { throw FileError.readOnly }
        guard offset >= 0, size >= 0, offset + size <= contents.count else {
            throw FileError.outOfBounds
        }
        if size == 0 { return }
        contents.withUnsafeMutableBytes { dst in
            dst.baseAddress!.advanced(by: offset).copyMemory(from: buffer, byteCount: size)
        }
    }
}
