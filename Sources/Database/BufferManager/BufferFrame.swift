/// Represents a single buffered page. Three RW locks:
///
/// - `mutex` protects `fixRequestCounter` and `isDirty`.
/// - `useMutex` is the page latch held by callers between
///   `BufferManager.fixPage` and `BufferManager.unfixPage` — exclusive for
///   write access, shared for read access.
/// - `dataMutex` is locked exclusively in `init` and unlocked in `readData`
///   so that any concurrent caller of `getData()` blocks until the first
///   disk read finishes.
public final class BufferFrame: @unchecked Sendable {
    public let pageId: UInt64

    let mutex = RWLock()
    let useMutex = RWLock()
    let dataMutex = RWLock()

    var dataPtr: UnsafeMutableRawPointer?
    var isDirty = false
    var fixRequestCounter = 1

    init(pageId: UInt64) {
        self.pageId = pageId
        dataMutex.lockExclusive()
    }

    deinit {
        dataPtr?.deallocate()
    }

    func checkIsFixed() -> Bool {
        mutex.lockShared()
        defer { mutex.unlock() }
        return fixRequestCounter > 0
    }

    func fix() {
        mutex.lockExclusive()
        defer { mutex.unlock() }
        fixRequestCounter += 1
    }

    func unfix(_ newIsDirty: Bool) {
        mutex.lockExclusive()
        defer { mutex.unlock() }
        fixRequestCounter -= 1
        isDirty = isDirty || newIsDirty
    }

    /// Allocates the data buffer, reads `size` bytes from the file at
    /// `offset` into it, and unlocks `dataMutex` so blocked `getData()`
    /// callers can proceed.
    func readData(from file: any File, offset: Int, size: Int) throws {
        let buf = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
        do {
            try file.readBlock(offset: offset, size: size, into: buf)
        } catch {
            buf.deallocate()
            dataMutex.unlock()
            throw error
        }
        self.dataPtr = buf
        dataMutex.unlock()
    }

    /// Returns a pointer to this page's data. Blocks (briefly) on the very
    /// first call until the initial disk read completes.
    public func getData() -> UnsafeMutableRawPointer {
        dataMutex.lockShared()
        defer { dataMutex.unlock() }
        return dataPtr!
    }

    /// Non-optional accessor used by SlottedPages and BTree (which were
    /// originally written against a stub `BufferFrame` whose data was a stored
    /// property). Delegates to `getData()` so the initial-read barrier is
    /// respected.
    public var data: UnsafeMutableRawPointer { getData() }
}
