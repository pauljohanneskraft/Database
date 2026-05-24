#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported platform: Mutex requires a POSIX libc")
#endif

/// Mutex wrapper around `pthread_mutex_t`. Used for short critical sections,
/// primarily the buffer manager's page-table guard. Use `RWLock` when the
/// read/write distinction is useful; use `Mutex` for plain mutual exclusion.
final class Mutex: @unchecked Sendable {
    private let ptr: UnsafeMutablePointer<pthread_mutex_t>

    init() {
        ptr = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
        ptr.initialize(to: pthread_mutex_t())
        let rc = pthread_mutex_init(ptr, nil)
        precondition(rc == 0, "pthread_mutex_init failed: \(rc)")
    }

    deinit {
        pthread_mutex_destroy(ptr)
        ptr.deinitialize(count: 1)
        ptr.deallocate()
    }

    func lock() {
        pthread_mutex_lock(ptr)
    }

    func unlock() {
        pthread_mutex_unlock(ptr)
    }
}
