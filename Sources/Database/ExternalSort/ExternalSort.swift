#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported platform: ExternalSort requires a POSIX libc for memcpy")
#endif

/// External k-way merge sort over fixed-stride binary records.
///
/// - Parameters:
///   - input: File of `numElements` records of `elementSize` bytes, laid out
///     contiguously. May be opened in `.read` mode.
///   - numElements: Number of records to sort.
///   - elementSize: Bytes per record. Must be > 0.
///   - output: File that receives the sorted records. Must be `.write`. Will
///     be `resize`d to `numElements * elementSize` bytes.
///   - memSize: Hard cap on the heap budget used for in-memory sorting and
///     merge buffers. Must be at least `2 * elementSize` to allow a working
///     merge phase. The implementation does not exceed this cap.
///   - compare: Strict `<` predicate over a pair of records. Receives raw
///     pointers to `elementSize` bytes each — typically loads the key field
///     via `loadUnaligned(fromByteOffset:as:)`.
///
/// The implementation does an initial chunk-sort pass of size
/// `memSize / elementSize` records, with two fast paths (forward-sorted and
/// backward-sorted), then a k-way streaming merge through an on-disk
/// temporary file. `k` is chosen per pass to maximise fan-in subject to
/// keeping a useful per-cursor read buffer.
public func externalSort(
    input: any File,
    numElements: Int,
    elementSize: Int,
    output: any File,
    memSize: Int,
    compare: (UnsafeRawPointer, UnsafeRawPointer) -> Bool
) throws {
    precondition(elementSize > 0, "elementSize must be positive")
    precondition(memSize >= 2 * elementSize, "memSize must hold at least two elements (got \(memSize) bytes for \(elementSize)-byte elements)")
    guard numElements > 0 else { return }

    let numMemElems = memSize / elementSize
    let totalByteCount = numElements * elementSize

    let intermediate = try PosixFile.makeTemporary()
    try intermediate.resize(totalByteCount)
    try output.resize(totalByteCount)

    // ---- Initial pass: chunk-sort runs of `numMemElems` elements into output. ----
    let lastSectionMin = UnsafeMutableRawPointer.allocate(byteCount: elementSize, alignment: 1)
    let lastSectionMax = UnsafeMutableRawPointer.allocate(byteCount: elementSize, alignment: 1)
    defer { lastSectionMin.deallocate(); lastSectionMax.deallocate() }
    var haveLastSection = false
    var isForwardSorted = true
    var isBackwardSorted = true

    do {
        let buf = UnsafeMutableRawPointer.allocate(byteCount: numMemElems * elementSize, alignment: 16)
        defer { buf.deallocate() }

        var startIndex = 0
        while startIndex < numElements {
            let n = min(numMemElems, numElements - startIndex)
            try input.readBlock(offset: startIndex * elementSize, size: n * elementSize, into: buf)
            sortBytes(buf: buf, count: n, elementSize: elementSize, compare: compare)

            let runMinPtr = UnsafeRawPointer(buf)
            let runMaxPtr = UnsafeRawPointer(buf.advanced(by: (n - 1) * elementSize))
            if haveLastSection {
                if compare(runMinPtr, lastSectionMax) { isForwardSorted = false }
                if compare(lastSectionMin, runMaxPtr) { isBackwardSorted = false }
            }
            memcpy(lastSectionMin, runMinPtr, elementSize)
            memcpy(lastSectionMax, runMaxPtr, elementSize)
            haveLastSection = true

            try output.writeBlock(buf, offset: startIndex * elementSize, size: n * elementSize)
            startIndex += numMemElems
        }
    }

    if isForwardSorted { return }

    // ---- Backward-sorted fast path. ----
    if isBackwardSorted {
        let buf = UnsafeMutableRawPointer.allocate(byteCount: numMemElems * elementSize, alignment: 16)
        defer { buf.deallocate() }

        var startIndex = 0
        while startIndex < numElements {
            let n = min(numMemElems, numElements - startIndex)
            try input.readBlock(offset: startIndex * elementSize, size: n * elementSize, into: buf)
            sortBytes(buf: buf, count: n, elementSize: elementSize, compare: compare)
            try output.writeBlock(buf, offset: (numElements - startIndex - n) * elementSize, size: n * elementSize)
            startIndex += numMemElems
        }
        return
    }

    // ---- Merge phase. ----
    let hasWrittenToIntermediate = try kWayExternalMerge(
        input: output,
        output: intermediate,
        runLength: numMemElems,
        numElements: numElements,
        numMemElems: numMemElems,
        elementSize: elementSize,
        compare: compare
    )

    if hasWrittenToIntermediate {
        let buf = UnsafeMutableRawPointer.allocate(byteCount: numMemElems * elementSize, alignment: 16)
        defer { buf.deallocate() }
        var startIndex = 0
        while startIndex < numElements {
            let n = min(numMemElems, numElements - startIndex)
            try intermediate.readBlock(offset: startIndex * elementSize, size: n * elementSize, into: buf)
            try output.writeBlock(buf, offset: startIndex * elementSize, size: n * elementSize)
            startIndex += numMemElems
        }
    }
}

/// UInt64 specialization. Thin wrapper around the generic API — kept so that
/// the existing test suite and any direct callers don't need to thread an
/// `elementSize`/comparator pair.
public func externalSort(input: any File, numValues: Int, output: any File, memSize: Int) throws {
    try externalSort(
        input: input,
        numElements: numValues,
        elementSize: MemoryLayout<UInt64>.size,
        output: output,
        memSize: memSize
    ) { a, b in
        a.loadUnaligned(as: UInt64.self) < b.loadUnaligned(as: UInt64.self)
    }
}

// MARK: - Merge internals

/// Per-pass fan-in cap. Picked to keep heap operations cheap and to avoid
/// shrinking per-cursor buffers below useful sizes for disk I/O.
private let kWayMaxFanIn = 64

/// Minimum elements per cursor buffer. Bigger means fewer refill calls;
/// smaller permits a higher fan-in for tight memory budgets.
private let kWayMinBufferElements = 32

@inline(__always)
private func chooseFanIn(remainingRuns: Int, numMemElems: Int) -> Int {
    let bufferCap = max(2, numMemElems / kWayMinBufferElements - 1)
    let fanIn = min(remainingRuns, min(kWayMaxFanIn, bufferCap))
    return max(2, fanIn)
}

/// Performs successive k-way merge passes until a single sorted run of
/// `numElements` exists. Returns `true` iff the last pass wrote into the
/// original `output` argument.
private func kWayExternalMerge(
    input initialInput: any File,
    output initialOutput: any File,
    runLength initialRunLength: Int,
    numElements: Int,
    numMemElems: Int,
    elementSize: Int,
    compare: (UnsafeRawPointer, UnsafeRawPointer) -> Bool
) throws -> Bool {
    var inFile: any File = initialInput
    var outFile: any File = initialOutput
    var runLength = initialRunLength
    var passes = 0

    while runLength < numElements {
        let remainingRuns = (numElements + runLength - 1) / runLength
        let k = chooseFanIn(remainingRuns: remainingRuns, numMemElems: numMemElems)
        let bufLen = max(1, numMemElems / (k + 1))

        try kWayMergePass(
            input: inFile,
            output: outFile,
            runLength: runLength,
            numElements: numElements,
            k: k,
            bufLen: bufLen,
            elementSize: elementSize,
            compare: compare
        )

        let tmp = inFile
        inFile = outFile
        outFile = tmp
        runLength &*= k
        passes &+= 1
    }

    return passes % 2 == 1
}

/// Single k-way merge pass. For each group of up to `k` adjacent runs of
/// length `runLength` in `input`, streams the merged result into `output`
/// using a min-heap over per-cursor read buffers.
private func kWayMergePass(
    input: any File,
    output: any File,
    runLength: Int,
    numElements: Int,
    k: Int,
    bufLen: Int,
    elementSize: Int,
    compare: (UnsafeRawPointer, UnsafeRawPointer) -> Bool
) throws {
    // One contiguous allocation for (k + 1) buffers of bufLen elements:
    //   slot 0       → output buffer
    //   slot 1 ... k → one input buffer per cursor
    let bufferStorage = UnsafeMutableRawPointer.allocate(
        byteCount: bufLen * (k + 1) * elementSize,
        alignment: 16
    )
    defer { bufferStorage.deallocate() }
    let outputBuffer = bufferStorage

    // Cursor state. Parallel arrays of scalars (Int) keep the hot loop tight;
    // cursorBuf carries the per-cursor base pointer (a constant slice of
    // `bufferStorage`).
    let cursorBuf = UnsafeMutablePointer<UnsafeMutableRawPointer>.allocate(capacity: k)
    let cursorEnd = UnsafeMutablePointer<Int>.allocate(capacity: k)
    let cursorBufIndex = UnsafeMutablePointer<Int>.allocate(capacity: k)
    let cursorBufLength = UnsafeMutablePointer<Int>.allocate(capacity: k)
    let cursorNextFile = UnsafeMutablePointer<Int>.allocate(capacity: k)
    defer {
        cursorBuf.deallocate()
        cursorEnd.deallocate()
        cursorBufIndex.deallocate()
        cursorBufLength.deallocate()
        cursorNextFile.deallocate()
    }
    for i in 0..<k {
        cursorBuf[i] = bufferStorage.advanced(by: bufLen * (i + 1) * elementSize)
    }

    // Min-heap of cursor indexes. Comparisons read each cursor's current head
    // through (`cursorBuf[idx]`, `cursorBufIndex[idx]`).
    let heap = UnsafeMutablePointer<Int>.allocate(capacity: k)
    defer { heap.deallocate() }

    @inline(__always)
    func head(_ cursorIdx: Int) -> UnsafeRawPointer {
        UnsafeRawPointer(cursorBuf[cursorIdx].advanced(by: cursorBufIndex[cursorIdx] * elementSize))
    }

    @inline(__always)
    func siftUp(_ position: Int) {
        var i = position
        while i > 0 {
            let parent = (i - 1) &>> 1
            if compare(head(heap[i]), head(heap[parent])) {
                let t = heap[i]; heap[i] = heap[parent]; heap[parent] = t
                i = parent
            } else {
                return
            }
        }
    }

    @inline(__always)
    func siftDown(_ position: Int, count: Int) {
        var i = position
        while true {
            let left = (i &<< 1) &+ 1
            let right = left &+ 1
            var smallest = i
            if left < count && compare(head(heap[left]), head(heap[smallest])) { smallest = left }
            if right < count && compare(head(heap[right]), head(heap[smallest])) { smallest = right }
            if smallest == i { return }
            let t = heap[i]; heap[i] = heap[smallest]; heap[smallest] = t
            i = smallest
        }
    }

    let groupRunLength = runLength &* k
    var groupStart = 0
    while groupStart < numElements {
        let groupEnd = min(numElements, groupStart + groupRunLength)

        // ---- Initialise cursors and prime the heap. ----
        var heapSize = 0
        for i in 0..<k {
            let runStart = min(groupStart + i &* runLength, groupEnd)
            let runEnd = min(runStart + runLength, groupEnd)
            cursorEnd[i] = runEnd
            cursorBufIndex[i] = 0
            cursorNextFile[i] = runStart

            let length = min(bufLen, runEnd - runStart)
            cursorBufLength[i] = length
            if length > 0 {
                try input.readBlock(
                    offset: runStart * elementSize,
                    size: length * elementSize,
                    into: cursorBuf[i]
                )
                cursorNextFile[i] = runStart + length
                heap[heapSize] = i
                siftUp(heapSize)
                heapSize &+= 1
            }
        }

        // ---- Merge loop. ----
        var outputBufferIndex = 0
        var outputFileIndex = groupStart

        while heapSize > 0 {
            let cursorIdx = heap[0]
            memcpy(
                outputBuffer.advanced(by: outputBufferIndex * elementSize),
                head(cursorIdx),
                elementSize
            )
            outputBufferIndex &+= 1

            if outputBufferIndex >= bufLen {
                try output.writeBlock(
                    outputBuffer,
                    offset: outputFileIndex * elementSize,
                    size: bufLen * elementSize
                )
                outputFileIndex &+= bufLen
                outputBufferIndex = 0
            }

            // Advance the popped cursor.
            cursorBufIndex[cursorIdx] &+= 1
            if cursorBufIndex[cursorIdx] >= cursorBufLength[cursorIdx] {
                let remaining = cursorEnd[cursorIdx] - cursorNextFile[cursorIdx]
                let length = min(bufLen, remaining)
                cursorBufLength[cursorIdx] = length
                cursorBufIndex[cursorIdx] = 0
                if length > 0 {
                    try input.readBlock(
                        offset: cursorNextFile[cursorIdx] * elementSize,
                        size: length * elementSize,
                        into: cursorBuf[cursorIdx]
                    )
                    cursorNextFile[cursorIdx] &+= length
                }
            }

            if cursorBufIndex[cursorIdx] < cursorBufLength[cursorIdx] {
                siftDown(0, count: heapSize)
            } else {
                heapSize &-= 1
                if heapSize > 0 {
                    heap[0] = heap[heapSize]
                    siftDown(0, count: heapSize)
                }
            }
        }

        if outputBufferIndex > 0 {
            try output.writeBlock(
                outputBuffer,
                offset: outputFileIndex * elementSize,
                size: outputBufferIndex * elementSize
            )
        }

        groupStart &+= groupRunLength
    }
}

// MARK: - In-memory chunk sort over a raw byte buffer

/// In-place median-of-three quicksort with insertion-sort cutoff. Records
/// are `elementSize` bytes each, accessed through `compare`. Uses two
/// `elementSize`-byte scratch buffers — strictly bounded extra memory.
private func sortBytes(
    buf: UnsafeMutableRawPointer,
    count n: Int,
    elementSize: Int,
    compare: (UnsafeRawPointer, UnsafeRawPointer) -> Bool
) {
    if n < 2 { return }
    let scratch = UnsafeMutableRawPointer.allocate(byteCount: elementSize, alignment: 1)
    defer { scratch.deallocate() }
    let pivot = UnsafeMutableRawPointer.allocate(byteCount: elementSize, alignment: 1)
    defer { pivot.deallocate() }

    quicksortBytes(
        buf: buf, lo: 0, hi: n - 1,
        elementSize: elementSize, compare: compare,
        scratch: scratch, pivot: pivot
    )
}

private func quicksortBytes(
    buf: UnsafeMutableRawPointer,
    lo: Int,
    hi: Int,
    elementSize: Int,
    compare: (UnsafeRawPointer, UnsafeRawPointer) -> Bool,
    scratch: UnsafeMutableRawPointer,
    pivot: UnsafeMutableRawPointer
) {
    @inline(__always)
    func elem(_ i: Int) -> UnsafeMutableRawPointer {
        buf.advanced(by: i * elementSize)
    }
    @inline(__always)
    func swap(_ i: Int, _ j: Int) {
        memcpy(scratch, elem(i), elementSize)
        memcpy(elem(i), elem(j), elementSize)
        memcpy(elem(j), scratch, elementSize)
    }

    var lo = lo
    var hi = hi
    while hi - lo >= 16 {
        // Median-of-three pivot.
        let mid = lo + (hi - lo) / 2
        if compare(elem(mid), elem(lo)) { swap(lo, mid) }
        if compare(elem(hi), elem(lo)) { swap(lo, hi) }
        if compare(elem(hi), elem(mid)) { swap(mid, hi) }
        memcpy(pivot, elem(mid), elementSize)
        // Stash pivot in `hi-1`; partition `lo+1 ... hi-2`.
        swap(mid, hi - 1)

        var i = lo
        var j = hi - 1
        while true {
            repeat { i += 1 } while compare(elem(i), pivot)
            repeat { j -= 1 } while compare(pivot, elem(j))
            if i >= j { break }
            swap(i, j)
        }
        // Restore pivot to its final position.
        swap(i, hi - 1)

        // Recurse on the smaller side, iterate on the larger.
        if i - lo < hi - i {
            quicksortBytes(
                buf: buf, lo: lo, hi: i - 1,
                elementSize: elementSize, compare: compare,
                scratch: scratch, pivot: pivot
            )
            lo = i + 1
        } else {
            quicksortBytes(
                buf: buf, lo: i + 1, hi: hi,
                elementSize: elementSize, compare: compare,
                scratch: scratch, pivot: pivot
            )
            hi = i - 1
        }
    }

    // Insertion sort the tail.
    if hi > lo {
        for i in (lo + 1)...hi {
            memcpy(scratch, buf.advanced(by: i * elementSize), elementSize)
            var j = i
            while j > lo && compare(scratch, buf.advanced(by: (j - 1) * elementSize)) {
                memcpy(buf.advanced(by: j * elementSize), buf.advanced(by: (j - 1) * elementSize), elementSize)
                j -= 1
            }
            memcpy(buf.advanced(by: j * elementSize), scratch, elementSize)
        }
    }
}
