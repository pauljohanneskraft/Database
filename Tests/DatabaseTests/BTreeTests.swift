import Foundation
import Testing
import Dispatch
@testable import Database

private typealias U64Tree = BTree<UInt64>

/// Allocate a zero-filled page-sized buffer for `LeafNode` / `InnerNode`
/// view tests.
private func allocateZeroPage(pageSize: Int) -> UnsafeMutableRawPointer {
    let buf = UnsafeMutableRawPointer.allocate(byteCount: pageSize, alignment: 16)
    buf.initializeMemory(as: UInt8.self, repeating: 0, count: pageSize)
    return buf
}

/// Linear-congruential PRNG seeded to match `std::mt19937_64{0}` callers in
/// the reference tests. The exact sequence differs from MT19937, but the
/// tests only require a deterministic shuffle / random-key stream — not a
/// specific shuffle order.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// Simple barrier — substitutes for `std::barrier` in `MultithreadWriters`.
/// Pthread barriers aren't available on Darwin, so we hand-roll one with a
/// mutex + condition variable.
private final class Barrier: @unchecked Sendable {
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

@Suite(.serialized)
struct BTreeTests {
    // MARK: - Capacity

    @Test func capacity() throws {
        // 8-byte UInt64 keys, 8-byte UInt64 values.
        func innerCap(_ pageSize: Int) -> Int { U64Tree.innerCapacity(pageSize: pageSize, keyStride: 8) }
        func leafCap(_ pageSize: Int) -> Int {
            U64Tree.leafCapacity(pageSize: pageSize, keyStride: 8, valueStride: 8)
        }
        func innerSize(_ pageSize: Int) -> Int { U64Tree.innerNodeSize(pageSize: pageSize, keyStride: 8) }
        func leafSize(_ pageSize: Int) -> Int {
            U64Tree.leafNodeSize(pageSize: pageSize, keyStride: 8, valueStride: 8)
        }

        // Both capacities are non-trivial — they are NOT 42.
        #expect(innerCap(1024) != 42)
        #expect(leafCap(1024) != 42)

        // Inner / leaf node sizes fit comfortably in a 1024-byte page and
        // make use of most of it (≥ 1000 bytes of payload).
        #expect(1000 <= innerSize(1024))
        #expect(innerSize(1024) <= 1024)
        #expect(1000 <= leafSize(1024))
        #expect(leafSize(1024) <= 1024)

        // Larger pages → larger fanout.
        let bigPage = 1 << 16
        #expect(64000 <= innerSize(bigPage))
        #expect(innerSize(bigPage) <= bigPage)
        #expect(64000 <= leafSize(bigPage))
        #expect(leafSize(bigPage) <= bigPage)
    }

    // MARK: - LeafNode (raw-buffer) tests

    @Test func leafNodeInsert() throws {
        let pageSize = 1024
        let buffer = allocateZeroPage(pageSize: pageSize)
        defer { buffer.deallocate() }

        let node = U64Tree.LeafNode(pointer: buffer, pageSize: pageSize)
        #expect(node.count == 0)

        let n = node.capacity
        for i in 0..<n {
            node.insert(UInt64(i), UInt64(i * 2))
            #expect(Int(node.count) == i + 1)
        }

        let keys = node.keysVector()
        let values = node.valuesVector()
        #expect(keys.count == n)
        #expect(values.count == n)

        for i in 0..<n {
            #expect(keys[i] == UInt64(i))
        }
        for i in 0..<n {
            #expect(values[i] == UInt64(i * 2))
        }
    }

    @Test func leafNodeSplit() throws {
        let pageSize = 1024
        let leftBuffer = allocateZeroPage(pageSize: pageSize)
        defer { leftBuffer.deallocate() }
        let rightBuffer = allocateZeroPage(pageSize: pageSize)
        defer { rightBuffer.deallocate() }

        let leftNode = U64Tree.LeafNode(pointer: leftBuffer, pageSize: pageSize)
        let n = leftNode.capacity
        #expect(leftNode.count == 0)

        for i in 0..<n {
            leftNode.insert(UInt64(i), UInt64(i * 2))
        }
        #expect(leftNode.keysVector().count == n)
        #expect(leftNode.valuesVector().count == n)

        let separator = leftNode.split(into: rightBuffer)
        let rightNode = U64Tree.LeafNode(pointer: rightBuffer, pageSize: pageSize)

        #expect(Int(leftNode.count) == n / 2 + 1)
        #expect(Int(rightNode.count) == n - (n / 2) - 1)
        #expect(separator == UInt64(n / 2))

        let leftKeys = leftNode.keysVector()
        let leftValues = leftNode.valuesVector()
        #expect(leftKeys.count == Int(leftNode.count))
        #expect(leftValues.count == Int(leftNode.count))
        for i in 0..<(Int(leftNode.count) - 1) {
            #expect(leftKeys[i] == UInt64(i))
        }
        for i in 0..<Int(leftNode.count) {
            #expect(leftValues[i] == UInt64(i * 2))
        }

        let rightKeys = rightNode.keysVector()
        let rightValues = rightNode.valuesVector()
        #expect(rightKeys.count == Int(rightNode.count))
        #expect(rightValues.count == Int(rightNode.count))
        for i in 0..<Int(rightNode.count) {
            #expect(rightKeys[i] == UInt64(Int(leftNode.count) + i))
        }
        for i in 0..<Int(rightNode.count) {
            #expect(rightValues[i] == UInt64((Int(leftNode.count) + i) * 2))
        }
    }

    // MARK: - Insert (full-tree)

    @Test func insertEmptyTree() throws {
        try TestSupport.withTempCwd {
            let bufferManager = BufferManager(pageSize: 1024, pageCount: 100)
            let tree = U64Tree(segmentId: 0, bufferManager: bufferManager)
            try tree.insert(42 as UInt64, 21)

            let rootPage = try bufferManager.fixPage(pageId: tree.root, exclusive: false)
            defer { bufferManager.unfixPage(rootPage, isDirty: false) }
            let rootNode = U64Tree.Node(pointer: rootPage.data)
            #expect(rootNode.isLeaf)
            #expect(rootNode.count > 0)
        }
    }

    @Test func insertLeafNode() throws {
        try TestSupport.withTempCwd {
            let bufferManager = BufferManager(pageSize: 1024, pageCount: 100)
            let tree = U64Tree(segmentId: 0, bufferManager: bufferManager)
            let leafCap = U64Tree.leafCapacity(pageSize: 1024, keyStride: 8, valueStride: 8)
            for i in 0..<leafCap {
                try tree.insert(UInt64(i), UInt64(2 * i))
            }

            let rootPage = try bufferManager.fixPage(pageId: tree.root, exclusive: false)
            defer { bufferManager.unfixPage(rootPage, isDirty: false) }
            let rootNode = U64Tree.Node(pointer: rootPage.data)
            #expect(rootNode.isLeaf)
            #expect(Int(rootNode.count) == leafCap)
        }
    }

    @Test func insertLeafNodeSplit() throws {
        try TestSupport.withTempCwd {
            let bufferManager = BufferManager(pageSize: 1024, pageCount: 100)
            let tree = U64Tree(segmentId: 0, bufferManager: bufferManager)
            let leafCap = U64Tree.leafCapacity(pageSize: 1024, keyStride: 8, valueStride: 8)
            for i in 0..<leafCap {
                try tree.insert(UInt64(i), UInt64(2 * i))
            }

            do {
                let rootPage = try bufferManager.fixPage(pageId: tree.root, exclusive: false)
                defer { bufferManager.unfixPage(rootPage, isDirty: false) }
                let rootNode = U64Tree.Node(pointer: rootPage.data)
                #expect(rootNode.isLeaf)
                #expect(Int(rootNode.count) == leafCap)
            }

            // Trigger a split.
            try tree.insert(424242 as UInt64, 42)

            let rootPage = try bufferManager.fixPage(pageId: tree.root, exclusive: false)
            defer { bufferManager.unfixPage(rootPage, isDirty: false) }
            let rootNode = U64Tree.Node(pointer: rootPage.data)
            #expect(!rootNode.isLeaf)
            #expect(rootNode.count == 2)
        }
    }

    // MARK: - Lookup

    @Test func lookupEmptyTree() throws {
        try TestSupport.withTempCwd {
            let bufferManager = BufferManager(pageSize: 1024, pageCount: 100)
            let tree = U64Tree(segmentId: 0, bufferManager: bufferManager)
            do { let _v = try tree.lookup(42 as UInt64); #expect(_v == nil) }
        }
    }

    @Test func lookupSingleLeaf() throws {
        try TestSupport.withTempCwd {
            let bufferManager = BufferManager(pageSize: 1024, pageCount: 100)
            let tree = U64Tree(segmentId: 0, bufferManager: bufferManager)
            let leafCap = U64Tree.leafCapacity(pageSize: 1024, keyStride: 8, valueStride: 8)

            for i in 0..<leafCap {
                try tree.insert(UInt64(i), UInt64(2 * i))
                do { let _v = try tree.lookup(UInt64(i)); #expect(_v != nil) }
            }
            for i in 0..<leafCap {
                let v = try tree.lookup(UInt64(i))
                #expect(v != nil)
                #expect(v == UInt64(2 * i))
            }
        }
    }

    @Test func lookupSingleSplit() throws {
        try TestSupport.withTempCwd {
            let bufferManager = BufferManager(pageSize: 1024, pageCount: 100)
            let tree = U64Tree(segmentId: 0, bufferManager: bufferManager)
            let leafCap = U64Tree.leafCapacity(pageSize: 1024, keyStride: 8, valueStride: 8)

            for i in 0..<leafCap {
                try tree.insert(UInt64(i), UInt64(2 * i))
            }
            try tree.insert(UInt64(leafCap), UInt64(2 * leafCap))
            do { let _v = try tree.lookup(UInt64(leafCap)); #expect(_v != nil) }

            for i in 0...leafCap {
                let v = try tree.lookup(UInt64(i))
                #expect(v != nil)
                #expect(v == UInt64(2 * i))
            }
        }
    }

    @Test func lookupMultipleSplitsIncreasing() throws {
        try TestSupport.withTempCwd {
            let bufferManager = BufferManager(pageSize: 1024, pageCount: 100)
            let tree = U64Tree(segmentId: 0, bufferManager: bufferManager)
            let n = 100 * U64Tree.leafCapacity(pageSize: 1024, keyStride: 8, valueStride: 8)

            for i in 0..<n {
                try tree.insert(UInt64(i), UInt64(2 * i))
                do { let _v = try tree.lookup(UInt64(i)); #expect(_v != nil) }
            }
            for i in 0..<n {
                let v = try tree.lookup(UInt64(i))
                #expect(v != nil)
                #expect(v == UInt64(2 * i))
            }
        }
    }

    @Test func lookupMultipleSplitsDecreasing() throws {
        try TestSupport.withTempCwd {
            let bufferManager = BufferManager(pageSize: 1024, pageCount: 100)
            let tree = U64Tree(segmentId: 0, bufferManager: bufferManager)
            let n = 10 * U64Tree.leafCapacity(pageSize: 1024, keyStride: 8, valueStride: 8)

            var i = n
            while i > 0 {
                try tree.insert(UInt64(i), UInt64(2 * i))
                do { let _v = try tree.lookup(UInt64(i)); #expect(_v != nil) }
                i -= 1
            }
            i = n
            while i > 0 {
                let v = try tree.lookup(UInt64(i))
                #expect(v != nil)
                #expect(v == UInt64(2 * i))
                i -= 1
            }
        }
    }

    @Test func lookupRandomNonRepeating() throws {
        try TestSupport.withTempCwd {
            let bufferManager = BufferManager(pageSize: 1024, pageCount: 100)
            let tree = U64Tree(segmentId: 0, bufferManager: bufferManager)
            let n = 10 * U64Tree.leafCapacity(pageSize: 1024, keyStride: 8, valueStride: 8)

            var keys: [UInt64] = (0..<n).map { UInt64(n + $0) }
            var rng = SeededGenerator(seed: 0)
            keys.shuffle(using: &rng)

            for i in 0..<n {
                try tree.insert(keys[i], 2 * keys[i])
                do { let _v = try tree.lookup(keys[i]); #expect(_v != nil) }
            }
            for i in 0..<n {
                let v = try tree.lookup(keys[i])
                #expect(v != nil)
                #expect(v == 2 * keys[i])
            }
        }
    }

    @Test func lookupRandomRepeating() throws {
        try TestSupport.withTempCwd {
            let bufferManager = BufferManager(pageSize: 1024, pageCount: 100)
            let tree = U64Tree(segmentId: 0, bufferManager: bufferManager)
            let n = 10 * U64Tree.leafCapacity(pageSize: 1024, keyStride: 8, valueStride: 8)

            var rng = SeededGenerator(seed: 0)
            var values: [UInt64] = Array(repeating: 0, count: 100)

            for i in 1..<n {
                let randKey = UInt64.random(in: 0...99, using: &rng)
                values[Int(randKey)] = UInt64(i)
                try tree.insert(randKey, UInt64(i))
                let v = try tree.lookup(randKey)
                #expect(v != nil)
                #expect(v == UInt64(i))
            }

            for i in 0..<100 {
                if values[i] == 0 { continue }
                let v = try tree.lookup(UInt64(i))
                #expect(v != nil)
                #expect(v == values[i])
            }
        }
    }

    // MARK: - Erase

    @Test func erase() throws {
        try TestSupport.withTempCwd {
            let bufferManager = BufferManager(pageSize: 1024, pageCount: 100)
            let tree = U64Tree(segmentId: 0, bufferManager: bufferManager)
            let leafCap = U64Tree.leafCapacity(pageSize: 1024, keyStride: 8, valueStride: 8)
            let n = 2 * leafCap

            for i in 0..<n {
                try tree.insert(UInt64(i), UInt64(2 * i))
            }
            for i in 0..<n {
                do { let _v = try tree.lookup(UInt64(i)); #expect(_v != nil) }
                try tree.erase(UInt64(i))
                do { let _v = try tree.lookup(UInt64(i)); #expect(_v == nil) }
            }
        }
    }

    // MARK: - Concurrency

    @Test func multithreadWriters() throws {
        try TestSupport.withTempCwd {
            let bufferManager = BufferManager(pageSize: 1024, pageCount: 100)
            let tree = U64Tree(segmentId: 0, bufferManager: bufferManager)
            let leafCap = U64Tree.leafCapacity(pageSize: 1024, keyStride: 8, valueStride: 8)

            let threadCount = 4
            let barrier = Barrier(count: threadCount)
            let group = DispatchGroup()

            for thread in 0..<threadCount {
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }
                    let startValue = thread * 2 * leafCap
                    let limit = startValue + 2 * leafCap
                    for i in startValue..<limit {
                        try! tree.insert(UInt64(i), UInt64(2 * i))
                    }
                    barrier.arriveAndWait()
                    for i in startValue..<limit {
                        let res = try! tree.lookup(UInt64(i))
                        #expect(res != nil)
                        #expect(res == UInt64(2 * i))
                    }
                }
            }
            group.wait()
        }
    }
}
