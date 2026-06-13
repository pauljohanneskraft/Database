import Foundation
@testable import Database

/// Test-only utilities shared across suites. Lives in a single place so the
/// `chdir` dance the real `BufferManager` needs (segment files are written
/// relative to cwd) is consistent everywhere.
enum TestSupport {
    /// Global lock that serialises `chdir` across every test in the process.
    /// Swift Testing parallelises across suites; `chdir` is process-global, so
    /// without this lock, two suites running concurrently would corrupt each
    /// other's segment files.
    private static let chdirLock = NSLock()

    /// Creates a unique temporary directory, `chdir`s into it, runs `body`,
    /// then restores the previous working directory and deletes the temp dir.
    /// `body`'s local values (BufferManagers, etc.) must be released before
    /// `chdir` is restored so flush-on-deinit happens inside the temp dir —
    /// the helper does *not* run after a thrown error if the BM held escaping
    /// closures, but for in-suite test usage this is sufficient.
    static func withTempCwd<T>(_ body: () throws -> T) throws -> T {
        chdirLock.lock()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("moderndbs_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let previous = FileManager.default.currentDirectoryPath
        guard FileManager.default.changeCurrentDirectoryPath(dir.path) else {
            try? FileManager.default.removeItem(at: dir)
            chdirLock.unlock()
            throw FileError.io("chdir failed")
        }
        defer {
            _ = FileManager.default.changeCurrentDirectoryPath(previous)
            try? FileManager.default.removeItem(at: dir)
            chdirLock.unlock()
        }
        return try body()
    }
}

/// A reusable one-shot barrier: the first `count - 1` callers of
/// `arriveAndWait()` block on a condition variable until the `count`th arrives,
/// then all proceed together. Because waiters *block* (rather than spin), the
/// dispatch worker pool can overcommit and schedule every participant even when
/// there are fewer cores than threads — unlike a busy-wait, which deadlocks on
/// core-constrained machines such as CI runners.
final class Barrier: @unchecked Sendable {
    private let total: Int
    private var arrived: Int = 0
    private let lock = NSCondition()

    init(count: Int) { self.total = count }

    func arriveAndWait() {
        lock.lock()
        arrived += 1
        if arrived == total {
            lock.broadcast()
        } else {
            while arrived < total { lock.wait() }
        }
        lock.unlock()
    }
}
