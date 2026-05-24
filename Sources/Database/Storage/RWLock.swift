#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported platform: RWLock requires a POSIX libc")
#endif

/// Thin wrapper around `pthread_rwlock_t`. `lockShared` acquires for reading,
/// `lockExclusive` acquires for writing, `unlock` releases either.
///
/// The pthread struct is heap-allocated via `UnsafeMutablePointer` to give it a
/// stable address that pthread functions can use across concurrent calls
/// without tripping Swift's exclusive-access checks.
final class RWLock: @unchecked Sendable {
    private let ptr: UnsafeMutablePointer<pthread_rwlock_t>

    init() {
        ptr = UnsafeMutablePointer<pthread_rwlock_t>.allocate(capacity: 1)
        ptr.initialize(to: pthread_rwlock_t())
        let rc = pthread_rwlock_init(ptr, nil)
        precondition(rc == 0, "pthread_rwlock_init failed: \(rc)")
    }

    deinit {
        pthread_rwlock_destroy(ptr)
        ptr.deinitialize(count: 1)
        ptr.deallocate()
    }

    func lockShared() {
        pthread_rwlock_rdlock(ptr)
    }

    func lockExclusive() {
        pthread_rwlock_wrlock(ptr)
    }

    func unlock() {
        pthread_rwlock_unlock(ptr)
    }
}
