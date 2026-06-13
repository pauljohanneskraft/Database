import Foundation
import Testing
@testable import Database

// Each test changes the working directory to a private temp directory because
// `BufferManager` writes segment files using the segment id as a relative
// path. `chdir` is process-global; `TestSupport.withTempCwd` guards it with a
// global lock so this suite is safe to run concurrently with other suites
// (`BTreeTests`) that also chdir.

@Suite(.serialized)
struct BufferManagerSuite {

    // MARK: - Helpers

    /// Delegates to `TestSupport.withTempCwd` — the global-lock variant — so
    /// concurrent suites that also chdir don't stomp on each other.
    static func withTempDir<T>(_ body: () throws -> T) throws -> T {
        try TestSupport.withTempCwd(body)
    }

    /// Reinterprets the page data as `UInt64` and returns a typed pointer to
    /// it. The frame's data buffer is always allocated with at least 16-byte
    /// alignment, so loading `UInt64` directly is safe.
    static func u64(_ frame: BufferFrame) -> UnsafeMutablePointer<UInt64> {
        frame.getData().assumingMemoryBound(to: UInt64.self)
    }

    /// Tiny xorshift64 RNG for tests that need a deterministic per-thread,
    /// reasonably uniform stream.
    struct XorShift64: RandomNumberGenerator {
        var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0xDEAD_BEEF_CAFE_BABE : seed }
        mutating func next() -> UInt64 {
            state ^= state &<< 13
            state ^= state &>> 7
            state ^= state &<< 17
            return state
        }
        mutating func uniform01() -> Double {
            // 53-bit precision in [0, 1)
            Double(next() >> 11) * (1.0 / Double(UInt64(1) << 53))
        }
    }

    /// Geometric distribution: number of failures before the first success
    /// at probability `p`. Support is `0, 1, 2, ...`, mean is `(1 - p) / p`.
    static func geometric(p: Double, using rng: inout XorShift64) -> Int {
        let u = max(rng.uniform01(), .ulpOfOne)
        let v = log(1 - u) / log(1 - p)
        return max(0, Int(v.rounded(.down)))
    }

    static func bernoulli(p: Double, using rng: inout XorShift64) -> Bool {
        rng.uniform01() < p
    }

    static func uniformInt(in range: ClosedRange<Int>, using rng: inout XorShift64) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(rng.next() % span)
    }

    /// Discrete distribution: returns an index `i` with probability
    /// proportional to `weights[i]`.
    static func discrete(weights: [Double], using rng: inout XorShift64) -> Int {
        let total = weights.reduce(0, +)
        let u = rng.uniform01() * total
        var cumulative = 0.0
        for i in weights.indices {
            cumulative += weights[i]
            if u < cumulative { return i }
        }
        return weights.indices.last ?? 0
    }

    // MARK: - Single-threaded tests

    @Test func fixSingle() throws {
        try Self.withTempDir {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            let expectedValues = [UInt64](repeating: 123, count: 1024 / MemoryLayout<UInt64>.size)
            do {
                let page = try bm.fixPage(pageId: 1, exclusive: true)
                expectedValues.withUnsafeBytes { src in
                    page.getData().copyMemory(from: src.baseAddress!, byteCount: 1024)
                }
                bm.unfixPage(page, isDirty: true)
                #expect(bm.getFifoList() == [1])
                #expect(bm.getLruList().isEmpty)
            }
            do {
                var values = [UInt64](repeating: 0, count: 1024 / MemoryLayout<UInt64>.size)
                let page = try bm.fixPage(pageId: 1, exclusive: false)
                values.withUnsafeMutableBytes { dst in
                    dst.baseAddress!.copyMemory(from: page.getData(), byteCount: 1024)
                }
                bm.unfixPage(page, isDirty: true)
                #expect(bm.getFifoList().isEmpty)
                #expect(bm.getLruList() == [1])
                #expect(values == expectedValues)
            }
        }
    }

    @Test func persistentRestart() throws {
        try Self.withTempDir {
            do {
                let bm = BufferManager(pageSize: 1024, pageCount: 10)
                for segment in UInt16(0)..<UInt16(3) {
                    for segmentPage in UInt64(0)..<UInt64(10) {
                        let pageId = (UInt64(segment) << 48) | segmentPage
                        let page = try bm.fixPage(pageId: pageId, exclusive: true)
                        Self.u64(page).pointee = UInt64(segment) * 10 + segmentPage
                        bm.unfixPage(page, isDirty: true)
                    }
                }
            }
            // First buffer manager is destroyed here, flushing dirty pages.
            do {
                let bm = BufferManager(pageSize: 1024, pageCount: 10)
                for segment in UInt16(0)..<UInt16(3) {
                    for segmentPage in UInt64(0)..<UInt64(10) {
                        let pageId = (UInt64(segment) << 48) | segmentPage
                        let page = try bm.fixPage(pageId: pageId, exclusive: false)
                        let value = Self.u64(page).pointee
                        bm.unfixPage(page, isDirty: false)
                        #expect(value == UInt64(segment) * 10 + segmentPage)
                    }
                }
            }
        }
    }

    @Test func fifoEvict() throws {
        try Self.withTempDir {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            for i in UInt64(1)..<UInt64(11) {
                let page = try bm.fixPage(pageId: i, exclusive: false)
                bm.unfixPage(page, isDirty: false)
            }
            #expect(bm.getFifoList() == Array(UInt64(1)...UInt64(10)))
            #expect(bm.getLruList().isEmpty)

            let extra = try bm.fixPage(pageId: 11, exclusive: false)
            bm.unfixPage(extra, isDirty: false)

            #expect(bm.getFifoList() == Array(UInt64(2)...UInt64(11)))
            #expect(bm.getLruList().isEmpty)
        }
    }

    @Test func bufferFull() throws {
        try Self.withTempDir {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            var pages: [BufferFrame] = []
            for i in UInt64(1)..<UInt64(11) {
                pages.append(try bm.fixPage(pageId: i, exclusive: false))
            }
            #expect(throws: BufferError.bufferFull) {
                _ = try bm.fixPage(pageId: 11, exclusive: false)
            }
            for page in pages {
                bm.unfixPage(page, isDirty: false)
            }
        }
    }

    @Test func moveToLru() throws {
        try Self.withTempDir {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            let fifoPage = try bm.fixPage(pageId: 1, exclusive: false)
            let lruPage = try bm.fixPage(pageId: 2, exclusive: false)
            bm.unfixPage(fifoPage, isDirty: false)
            bm.unfixPage(lruPage, isDirty: false)
            #expect(bm.getFifoList() == [1, 2])
            #expect(bm.getLruList().isEmpty)

            let lruPage2 = try bm.fixPage(pageId: 2, exclusive: false)
            bm.unfixPage(lruPage2, isDirty: false)
            #expect(bm.getFifoList() == [1])
            #expect(bm.getLruList() == [2])
        }
    }

    @Test func lruRefresh() throws {
        try Self.withTempDir {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            for _ in 0..<2 {
                let page = try bm.fixPage(pageId: 1, exclusive: false)
                bm.unfixPage(page, isDirty: false)
            }
            for _ in 0..<2 {
                let page = try bm.fixPage(pageId: 2, exclusive: false)
                bm.unfixPage(page, isDirty: false)
            }
            #expect(bm.getFifoList().isEmpty)
            #expect(bm.getLruList() == [1, 2])

            let page1 = try bm.fixPage(pageId: 1, exclusive: false)
            bm.unfixPage(page1, isDirty: false)
            #expect(bm.getFifoList().isEmpty)
            #expect(bm.getLruList() == [2, 1])
        }
    }

    // MARK: - Multi-threaded tests

    @Test(.timeLimit(.minutes(1))) func multithreadParallelFix() throws {
        try Self.withTempDir {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            let group = DispatchGroup()
            for i in 0..<UInt64(4) {
                DispatchQueue.global().async(group: group) {
                    do {
                        let page1 = try bm.fixPage(pageId: i, exclusive: false)
                        let page2 = try bm.fixPage(pageId: i + 4, exclusive: false)
                        bm.unfixPage(page1, isDirty: false)
                        bm.unfixPage(page2, isDirty: false)
                    } catch {
                        Issue.record("fixPage threw: \(error)")
                    }
                }
            }
            group.wait()
            #expect(bm.getFifoList().sorted() == Array(UInt64(0)...UInt64(7)))
            #expect(bm.getLruList().isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1))) func multithreadExclusiveAccess() throws {
        try Self.withTempDir {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            do {
                let page = try bm.fixPage(pageId: 0, exclusive: true)
                page.getData().initializeMemory(as: UInt8.self, repeating: 0, count: 1024)
                bm.unfixPage(page, isDirty: true)
            }
            let group = DispatchGroup()
            for _ in 0..<4 {
                DispatchQueue.global().async(group: group) {
                    for _ in 0..<1000 {
                        do {
                            let page = try bm.fixPage(pageId: 0, exclusive: true)
                            Self.u64(page).pointee += 1
                            bm.unfixPage(page, isDirty: true)
                        } catch {
                            Issue.record("fixPage threw: \(error)")
                        }
                    }
                }
            }
            group.wait()
            #expect(bm.getFifoList().isEmpty)
            #expect(bm.getLruList() == [0])
            let page = try bm.fixPage(pageId: 0, exclusive: false)
            let value = Self.u64(page).pointee
            bm.unfixPage(page, isDirty: false)
            #expect(value == 4000)
        }
    }

    @Test(.timeLimit(.minutes(1))) func blockedThreadsHoldsNoLocks() throws {
        try Self.withTempDir {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            for i in UInt64(0)..<UInt64(2) {
                let page = try bm.fixPage(pageId: i, exclusive: true)
                page.getData().initializeMemory(as: UInt8.self, repeating: 0, count: 1024)
                bm.unfixPage(page, isDirty: true)
            }

            let blockedSem = DispatchSemaphore(value: 0)
            let releaseSem = DispatchSemaphore(value: 0)
            let blockingDone = DispatchSemaphore(value: 0)
            let blockedDone = DispatchSemaphore(value: 0)

            // Holds page 0 exclusive and waits to be released.
            DispatchQueue.global().async {
                defer { blockingDone.signal() }
                do {
                    let page = try bm.fixPage(pageId: 0, exclusive: true)
                    blockedSem.signal()
                    let p = Self.u64(page)
                    p.pointee += 1
                    releaseSem.wait()
                    #expect(p.pointee == 1)
                    bm.unfixPage(page, isDirty: true)
                } catch {
                    Issue.record("blocking fixPage threw: \(error)")
                }
            }

            blockedSem.wait()

            // Blocks waiting for the page-0 latch; we don't expect this to make
            // progress until the main thread releases the blocking thread.
            DispatchQueue.global().async {
                defer { blockedDone.signal() }
                do {
                    let page = try bm.fixPage(pageId: 0, exclusive: true)
                    let p = Self.u64(page)
                    #expect(p.pointee == 1)
                    bm.unfixPage(page, isDirty: false)
                } catch {
                    Issue.record("blocked fixPage threw: \(error)")
                }
            }

            // While the blocked thread is parked on page-0's `useMutex`, page-1
            // operations must still complete — proving `BufferManager` doesn't
            // hold queue/file locks across the page latch acquisition.
            let group = DispatchGroup()
            for _ in 0..<4 {
                DispatchQueue.global().async(group: group) {
                    for _ in 0..<1000 {
                        do {
                            let page = try bm.fixPage(pageId: 1, exclusive: false)
                            #expect(Self.u64(page).pointee == 0)
                            bm.unfixPage(page, isDirty: false)
                        } catch {
                            Issue.record("page-1 fixPage threw: \(error)")
                        }
                    }
                }
            }
            group.wait()

            releaseSem.signal()
            blockingDone.wait()
            blockedDone.wait()
        }
    }

    @Test(.timeLimit(.minutes(1))) func multithreadBufferFull() throws {
        try Self.withTempDir {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            let bufferFullCount = LockedCounter()
            // Blocking barrier: every worker must reach this point before any of
            // them releases its fixed pages, so the unfix order can't bias which
            // thread proceeds first. It blocks (not busy-waits) so the dispatch
            // pool can overcommit and schedule all 4 workers even when there are
            // fewer cores than threads — a busy-wait deadlocks on CI runners.
            let barrier = Barrier(count: 4)
            let group = DispatchGroup()
            for i in 0..<UInt64(4) {
                DispatchQueue.global().async(group: group) {
                    var pages: [BufferFrame] = []
                    pages.reserveCapacity(4)
                    for j in 0..<UInt64(4) {
                        do {
                            pages.append(try bm.fixPage(pageId: i + j * 4, exclusive: false))
                        } catch BufferError.bufferFull {
                            bufferFullCount.increment()
                        } catch {
                            Issue.record("unexpected error: \(error)")
                        }
                    }
                    barrier.arriveAndWait()
                    for page in pages {
                        bm.unfixPage(page, isDirty: false)
                    }
                }
            }
            group.wait()
            #expect(bm.getFifoList().count == 10)
            #expect(bm.getLruList().isEmpty)
            #expect(bufferFullCount.value == 6)
        }
    }

    @Test(.timeLimit(.minutes(1))) func multithreadManyPages() throws {
        try Self.withTempDir {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            let group = DispatchGroup()
            for i in 0..<UInt64(4) {
                DispatchQueue.global().async(group: group) {
                    var rng = XorShift64(seed: i &+ 1)
                    for _ in 0..<10_000 {
                        let pageId = UInt64(Self.geometric(p: 0.1, using: &rng))
                        do {
                            let page = try bm.fixPage(pageId: pageId, exclusive: false)
                            bm.unfixPage(page, isDirty: false)
                        } catch {
                            Issue.record("fixPage threw: \(error)")
                        }
                    }
                }
            }
            group.wait()
        }
    }

    @Test(.timeLimit(.minutes(1))) func multithreadReaderWriter() throws {
        try Self.withTempDir {
            // Pre-zero every page in segments 0..=3, pages 0..=100. The first
            // buffer manager is destroyed before the test workload starts so
            // the cache begins cold.
            do {
                let bm = BufferManager(pageSize: 1024, pageCount: 10)
                for segment in UInt16(0)...UInt16(3) {
                    for segmentPage in UInt64(0)...UInt64(100) {
                        let pageId = (UInt64(segment) << 48) | segmentPage
                        let page = try bm.fixPage(pageId: pageId, exclusive: true)
                        page.getData().initializeMemory(as: UInt8.self, repeating: 0, count: 1024)
                        bm.unfixPage(page, isDirty: true)
                    }
                }
            }

            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            let aborts = LockedCounter()
            let group = DispatchGroup()
            for i in 0..<UInt64(4) {
                DispatchQueue.global().async(group: group) {
                    var rng = XorShift64(seed: i &+ 1)
                    var scanSums = [UInt64](repeating: 0, count: 4)
                    for _ in 0..<100 {
                        let segment = Self.discrete(weights: [12, 5, 2, 1], using: &rng)
                        let segmentShift = UInt64(segment) << 48
                        if Self.bernoulli(p: 0.05, using: &rng) {
                            // scan
                            var scanSum: UInt64 = 0
                            for segmentPage in UInt64(0)...UInt64(100) {
                                let pageId = segmentShift | segmentPage
                                var page: BufferFrame?
                                while page == nil {
                                    do {
                                        page = try bm.fixPage(pageId: pageId, exclusive: false)
                                    } catch BufferError.bufferFull {
                                        // retry
                                    } catch {
                                        Issue.record("scan unexpected: \(error)")
                                        break
                                    }
                                }
                                guard let p = page else { break }
                                scanSum &+= Self.u64(p).pointee
                                bm.unfixPage(p, isDirty: false)
                            }
                            #expect(scanSum >= scanSums[segment])
                            scanSums[segment] = scanSum
                        } else {
                            // point query
                            let numPages = Self.geometric(p: 0.5, using: &rng) + 1
                            var pages: [BufferFrame] = []
                            let unfixAll = {
                                for page in pages.reversed() {
                                    bm.unfixPage(page, isDirty: false)
                                }
                                pages.removeAll(keepingCapacity: true)
                            }
                            var aborted = false
                            for _ in 0..<(numPages - 1) {
                                let segmentPage = UInt64(Self.uniformInt(in: 0...100, using: &rng))
                                let pageId = segmentShift | segmentPage
                                do {
                                    pages.append(try bm.fixPage(pageId: pageId, exclusive: false))
                                } catch BufferError.bufferFull {
                                    aborts.increment()
                                    aborted = true
                                    break
                                } catch {
                                    Issue.record("point unexpected: \(error)")
                                    aborted = true
                                    break
                                }
                            }
                            if !aborted {
                                unfixAll()
                                let segmentPage = UInt64(Self.uniformInt(in: 0...100, using: &rng))
                                let pageId = segmentShift | segmentPage
                                if Self.bernoulli(p: 0.6, using: &rng) {
                                    do {
                                        let page = try bm.fixPage(pageId: pageId, exclusive: false)
                                        bm.unfixPage(page, isDirty: false)
                                    } catch BufferError.bufferFull {
                                        aborts.increment()
                                    } catch {
                                        Issue.record("point read unexpected: \(error)")
                                    }
                                } else {
                                    do {
                                        let page = try bm.fixPage(pageId: pageId, exclusive: true)
                                        Self.u64(page).pointee &+= 1
                                        bm.unfixPage(page, isDirty: true)
                                    } catch BufferError.bufferFull {
                                        aborts.increment()
                                    } catch {
                                        Issue.record("point write unexpected: \(error)")
                                    }
                                }
                            }
                            unfixAll()
                        }
                    }
                }
            }
            group.wait()
            #expect(aborts.value < 20)
        }
    }
}

/// Lock-protected counter used by the multi-threaded tests.
final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func increment() {
        lock.lock(); defer { lock.unlock() }
        _value += 1
    }
}
