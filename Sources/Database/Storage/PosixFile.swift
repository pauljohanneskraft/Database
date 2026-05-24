#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported platform: PosixFile requires a POSIX libc")
#endif

/// File implementation backed by a POSIX file descriptor.
public final class PosixFile: File, @unchecked Sendable {
    public let mode: FileMode
    private let fd: Int32
    private let sizeMutex = Mutex()
    private var cachedSize: Int

    private init(mode: FileMode, fd: Int32, size: Int) {
        self.mode = mode
        self.fd = fd
        self.cachedSize = size
    }

    public convenience init(filename: String, mode: FileMode) throws {
        let flags: Int32
        switch mode {
        case .read:  flags = O_RDONLY | O_CLOEXEC
        case .write: flags = O_RDWR | O_CREAT | O_CLOEXEC
        }
        let fd = filename.withCString { open($0, flags, 0o666) }
        guard fd >= 0 else { throw FileError.io(Self.lastErrorMessage("open")) }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            throw FileError.io(Self.lastErrorMessage("fstat"))
        }
        self.init(mode: mode, fd: fd, size: Int(st.st_size))
    }

    deinit { close(fd) }

    public var size: Int {
        sizeMutex.lock()
        defer { sizeMutex.unlock() }
        return cachedSize
    }

    public func resize(_ newSize: Int) throws {
        guard mode == .write else { throw FileError.readOnly }
        guard ftruncate(fd, off_t(newSize)) == 0 else {
            throw FileError.io(Self.lastErrorMessage("ftruncate"))
        }
        sizeMutex.lock()
        cachedSize = newSize
        sizeMutex.unlock()
    }

    public func readBlock(offset: Int, size: Int, into buffer: UnsafeMutableRawPointer) throws {
        guard offset >= 0, size >= 0, offset + size <= self.size else {
            throw FileError.outOfBounds
        }
        var remaining = size
        var off = off_t(offset)
        var ptr = buffer
        while remaining > 0 {
            let n = pread(fd, ptr, remaining, off)
            if n > 0 {
                remaining -= n
                off += off_t(n)
                ptr = ptr.advanced(by: n)
            } else if n == 0 {
                throw FileError.io("pread: unexpected EOF")
            } else if errno == EINTR {
                continue
            } else {
                throw FileError.io(Self.lastErrorMessage("pread"))
            }
        }
    }

    public func writeBlock(_ buffer: UnsafeRawPointer, offset: Int, size: Int) throws {
        guard mode == .write else { throw FileError.readOnly }
        guard offset >= 0, size >= 0, offset + size <= self.size else {
            throw FileError.outOfBounds
        }
        var remaining = size
        var off = off_t(offset)
        var ptr = buffer
        while remaining > 0 {
            let n = pwrite(fd, ptr, remaining, off)
            if n > 0 {
                remaining -= n
                off += off_t(n)
                ptr = ptr.advanced(by: n)
            } else if errno == EINTR {
                continue
            } else {
                throw FileError.io(Self.lastErrorMessage("pwrite"))
            }
        }
    }

    public static func openFile(filename: String, mode: FileMode) throws -> any File {
        try PosixFile(filename: filename, mode: mode)
    }

    /// Creates an anonymous temporary file. The file is unlinked immediately
    /// so the OS reclaims its space when the descriptor is closed.
    public static func makeTemporary() throws -> PosixFile {
        let template = "/tmp/moderndbs_XXXXXX"
        let cBufLen = template.utf8.count + 1
        let cBuf = UnsafeMutablePointer<CChar>.allocate(capacity: cBufLen)
        defer { cBuf.deallocate() }
        template.withCString { src in
            _ = strcpy(cBuf, src)
        }
        let fd = mkstemp(cBuf)
        guard fd >= 0 else { throw FileError.io(lastErrorMessage("mkstemp")) }
        unlink(cBuf)
        return PosixFile(mode: .write, fd: fd, size: 0)
    }

    private static func lastErrorMessage(_ syscall: String) -> String {
        let msg = String(cString: strerror(errno))
        return "\(syscall): \(msg)"
    }
}
