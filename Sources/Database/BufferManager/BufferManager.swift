/// 2Q-replacement buffer manager.
///
/// Page ids are 64-bit, split as `segment_id = pageId >> 48` (most-significant
/// 16 bits) and `segment_page_id = pageId & ((1 << 48) - 1)`. Each segment is
/// persisted to a file in the current working directory whose name is the
/// decimal segment id.
///
/// Lock-ordering invariant: when both queue mutexes need to be held
/// simultaneously, `fifoQueueMutex` is acquired before `lruQueueMutex`.
public final class BufferManager: @unchecked Sendable {
    public let pageSize: Int
    public let pageCount: Int

    private let filesMutex = RWLock()
    private var files: [UInt16: any File] = [:]

    private let fifoQueueMutex = RWLock()
    private var fifoQueue: [BufferFrame] = []

    private let lruQueueMutex = RWLock()
    private var lruQueue: [BufferFrame] = []

    public init(pageSize: Int, pageCount: Int) {
        self.pageSize = pageSize
        self.pageCount = pageCount
    }

    deinit {
        for frame in fifoQueue {
            try? writeFrameIfNeeded(frame)
        }
        for frame in lruQueue {
            try? writeFrameIfNeeded(frame)
        }
    }

    /// Returns a `BufferFrame` for `pageId`, loading it from disk if needed.
    /// On return, the page latch is held in the requested mode and must be
    /// released by a matching call to `unfixPage`. Throws `BufferError.bufferFull`
    /// when the buffer is at capacity and every frame is currently fixed.
    public func fixPage(pageId: UInt64, exclusive: Bool) throws -> BufferFrame {
        // Phase 1: optimistic lookup under shared queue locks so concurrent
        // hits don't serialise.
        if let frame = findResidentFrame(pageId: pageId) {
            if exclusive {
                frame.useMutex.lockExclusive()
            } else {
                frame.useMutex.lockShared()
            }
            return frame
        }

        // Miss: build a fresh frame, then insert-or-find it atomically under
        // the exclusive queue locks. The re-check inside `insertOrFindFrame`
        // is what makes concurrent first-time fixes of the same cold page
        // converge on a single frame instead of each creating their own.
        let newFrame = BufferFrame(pageId: pageId)
        if exclusive {
            newFrame.useMutex.lockExclusive()
        } else {
            newFrame.useMutex.lockShared()
        }

        let outcome: InsertOutcome
        do {
            outcome = try insertOrFindFrame(newFrame)
        } catch {
            // Unlock the latches we acquired so the abandoned frame can be
            // safely destroyed without tripping pthread_rwlock_destroy on
            // a held lock.
            newFrame.useMutex.unlock()
            newFrame.dataMutex.unlock()
            throw error
        }

        switch outcome {
        case .existing(let frame):
            // Another thread created the frame for this page id first. Discard
            // ours (release its latches and let it deallocate) and latch the
            // winner instead. The winner's `getData()` still blocks on its own
            // `dataMutex` until that thread's disk read completes.
            newFrame.useMutex.unlock()
            newFrame.dataMutex.unlock()
            if exclusive {
                frame.useMutex.lockExclusive()
            } else {
                frame.useMutex.lockShared()
            }
            return frame
        case .inserted(let evicted):
            if let evicted {
                try writeFrameIfNeeded(evicted)
            }
            let offset = Int(Self.segmentPageId(of: pageId)) * pageSize
            let file = try findFile(for: pageId)
            try newFrame.readData(from: file, offset: offset, size: pageSize)
            return newFrame
        }
    }

    /// Releases the page latch held by `frame` and decrements its fix counter.
    /// When `isDirty` is true, the page is marked dirty so it will be written
    /// back to disk eventually (on eviction or `BufferManager` teardown).
    public func unfixPage(_ frame: BufferFrame, isDirty: Bool) {
        frame.useMutex.unlock()
        frame.unfix(isDirty)
    }

    /// Returns the page ids of every page currently in the FIFO queue, in
    /// FIFO order. Not thread-safe — concurrent callers of `fixPage` may be
    /// mutating the queue.
    public func getFifoList() -> [UInt64] {
        fifoQueue.map(\.pageId)
    }

    /// Returns the page ids of every page currently in the LRU queue, in
    /// LRU order. Not thread-safe.
    public func getLruList() -> [UInt64] {
        lruQueue.map(\.pageId)
    }

    /// Returns the segment id (most-significant 16 bits) of `pageId`.
    public static func segmentId(of pageId: UInt64) -> UInt16 {
        UInt16(pageId >> 48)
    }

    /// Returns the segment-relative page id (least-significant 48 bits) of `pageId`.
    public static func segmentPageId(of pageId: UInt64) -> UInt64 {
        pageId & ((UInt64(1) << 48) - 1)
    }

    /// Composes a 64-bit page id from a segment id (high 16 bits) and a
    /// segment-relative page id (low 48 bits). Inverse of
    /// `segmentId(of:)` / `segmentPageId(of:)`.
    public static func pageId(segmentId: UInt16, segmentPageId: UInt64) -> UInt64 {
        (UInt64(segmentId) << 48) | segmentPageId
    }

    // MARK: - Private helpers

    /// Looks up (or opens) the segment file for `pageId` and resizes it so it
    /// is large enough to hold `segmentPageId + 1` pages.
    private func findFile(for pageId: UInt64) throws -> any File {
        let segmentId = Self.segmentId(of: pageId)
        let minSize = pageSize * Int(Self.segmentPageId(of: pageId) + 1)

        filesMutex.lockExclusive()
        defer { filesMutex.unlock() }

        let file: any File
        if let existing = files[segmentId] {
            file = existing
        } else {
            file = try PosixFile.openFile(filename: String(segmentId), mode: .write)
            files[segmentId] = file
        }

        if file.size < minSize {
            try file.resize(max(file.size, minSize))
        }
        return file
    }

    /// Looks for a resident frame for `pageId` under shared queue locks. On a
    /// hit the frame is fixed and promoted (FIFO→LRU, or refreshed within LRU)
    /// before being returned; the page latch is acquired by the caller.
    private func findResidentFrame(pageId: UInt64) -> BufferFrame? {
        var isInFifoQueue = false
        var result: BufferFrame?

        fifoQueueMutex.lockShared()
        for frame in fifoQueue where frame.pageId == pageId {
            frame.fix()
            isInFifoQueue = true
            result = frame
            break
        }
        fifoQueueMutex.unlock()

        if result == nil {
            lruQueueMutex.lockShared()
            for frame in lruQueue where frame.pageId == pageId {
                frame.fix()
                result = frame
                break
            }
            lruQueueMutex.unlock()
        }

        guard let result else { return nil }
        moveToLru(result, fromFifo: isInFifoQueue)
        return result
    }

    /// Promotes a hit frame: a FIFO frame moves to the LRU queue, an LRU frame
    /// is refreshed to the tail. Tolerates the frame having been moved by a
    /// concurrent fix between the shared-lock search and this exclusive update.
    private func moveToLru(_ frame: BufferFrame, fromFifo: Bool) {
        if fromFifo {
            fifoQueueMutex.lockExclusive()
            lruQueueMutex.lockExclusive()
            defer {
                lruQueueMutex.unlock()
                fifoQueueMutex.unlock()
            }
            if let idx = fifoQueue.firstIndex(where: { $0 === frame }) {
                fifoQueue.remove(at: idx)
                lruQueue.append(frame)
            } else if let idx = lruQueue.firstIndex(where: { $0 === frame }) {
                lruQueue.remove(at: idx)
                lruQueue.append(frame)
            }
        } else {
            lruQueueMutex.lockExclusive()
            defer { lruQueueMutex.unlock() }
            if let idx = lruQueue.firstIndex(where: { $0 === frame }) {
                lruQueue.remove(at: idx)
                lruQueue.append(frame)
            }
        }
    }

    /// Result of `insertOrFindFrame`: either the new frame was inserted (with
    /// the frame it evicted, if any) or an existing frame for the same page id
    /// was found and should be used instead.
    private enum InsertOutcome {
        case inserted(evicted: BufferFrame?)
        case existing(BufferFrame)
    }

    /// Inserts `newFrame`, but first re-checks both queues under the exclusive
    /// locks: if another thread already created a frame for the same page id,
    /// that frame is fixed, promoted, and returned via `.existing` so the
    /// caller can discard `newFrame`. Otherwise `newFrame` is inserted into the
    /// FIFO queue, evicting an unfixed frame (FIFO first, then LRU) if the
    /// buffer is at capacity. Throws `BufferError.bufferFull` when every frame
    /// is fixed.
    private func insertOrFindFrame(_ newFrame: BufferFrame) throws -> InsertOutcome {
        fifoQueueMutex.lockExclusive()
        lruQueueMutex.lockExclusive()
        defer {
            lruQueueMutex.unlock()
            fifoQueueMutex.unlock()
        }

        let pageId = newFrame.pageId
        if let idx = fifoQueue.firstIndex(where: { $0.pageId == pageId }) {
            let existing = fifoQueue[idx]
            existing.fix()
            fifoQueue.remove(at: idx)
            lruQueue.append(existing)
            return .existing(existing)
        }
        if let idx = lruQueue.firstIndex(where: { $0.pageId == pageId }) {
            let existing = lruQueue[idx]
            existing.fix()
            lruQueue.remove(at: idx)
            lruQueue.append(existing)
            return .existing(existing)
        }

        let queueSize = fifoQueue.count + lruQueue.count
        if queueSize < pageCount {
            fifoQueue.append(newFrame)
            return .inserted(evicted: nil)
        }

        for idx in fifoQueue.indices {
            let frame = fifoQueue[idx]
            if !frame.checkIsFixed() {
                fifoQueue.remove(at: idx)
                fifoQueue.append(newFrame)
                return .inserted(evicted: frame)
            }
        }

        for idx in lruQueue.indices {
            let frame = lruQueue[idx]
            if !frame.checkIsFixed() {
                lruQueue.remove(at: idx)
                fifoQueue.append(newFrame)
                return .inserted(evicted: frame)
            }
        }

        throw BufferError.bufferFull
    }

    /// Writes the frame to disk if it is currently dirty. Reads the dirty
    /// flag under a shared lock and releases it before doing any I/O so the
    /// queue/file mutexes are not held across `write_block`.
    private func writeFrameIfNeeded(_ frame: BufferFrame) throws {
        frame.mutex.lockShared()
        let dirty = frame.isDirty
        frame.mutex.unlock()
        if !dirty { return }

        let offset = Int(Self.segmentPageId(of: frame.pageId)) * pageSize
        let file = try findFile(for: frame.pageId)
        try file.writeBlock(frame.getData(), offset: offset, size: pageSize)
    }
}
