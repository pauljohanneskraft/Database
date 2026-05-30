#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported platform: BTree requires a POSIX libc for memmove/memcpy")
#endif

/// In-memory B+-Tree on top of `BufferManager`.
///
/// The key is a **runtime-width raw byte string** (`keyStride` bytes) ordered by
/// a `less` comparator supplied at construction — the same shape `ExternalSort`
/// uses (runtime stride + closure) rather than a compile-time generic key type.
/// That lets an index key be exactly its column's declared `CHAR(n)` width (or 8
/// bytes for an integer key) instead of a fixed cap, while the node layout stays
/// fixed-stride. `Value` stays a `BitwiseCopyable` generic (always `UInt64` here:
/// a `TID.rawValue`). Typed conveniences for `UInt64` / `Int64` / char keys are
/// at the bottom of the file.
///
/// Concurrency: per-page latches in `BufferFrame` (acquired through
/// `fixPage`/`unfixPage`), a root-level `RWLock` for the `root`/`rootLevel`
/// fields, and a two-phase optimistic `insert` that retries with the root
/// locked exclusively if a split would propagate to the root.
public final class BTree<Value>: Segment, @unchecked Sendable
where Value: BitwiseCopyable {

    /// Bytes per key (fixed for the life of the tree). Page-id child pointers
    /// are always 8 bytes; keys/values are accessed unaligned, so the on-page
    /// layout needs no alignment padding.
    public let keyStride: Int
    public let valueStride: Int
    /// Strict `<` over two `keyStride`-byte key regions.
    private let less: (UnsafeRawPointer, UnsafeRawPointer) -> Bool

    // MARK: - Layout

    /// Capacity of an `InnerNode`: `(pageSize - 4 + keyStride) / (keyStride + 8)`
    /// (4-byte header; `(cap - 1)` keys; `cap` 8-byte child page ids).
    public static func innerCapacity(pageSize: Int, keyStride: Int) -> Int {
        (pageSize - 4 + keyStride) / (keyStride + 8)
    }

    /// Capacity of a `LeafNode`: `(pageSize - 4) / (keyStride + valueStride)`.
    public static func leafCapacity(pageSize: Int, keyStride: Int, valueStride: Int) -> Int {
        (pageSize - 4) / (keyStride + valueStride)
    }

    /// Byte size occupied by an `InnerNode`.
    public static func innerNodeSize(pageSize: Int, keyStride: Int) -> Int {
        let cap = innerCapacity(pageSize: pageSize, keyStride: keyStride)
        return 4 + (cap - 1) * keyStride + cap * 8
    }

    /// Byte size occupied by a `LeafNode`.
    public static func leafNodeSize(pageSize: Int, keyStride: Int, valueStride: Int) -> Int {
        let cap = leafCapacity(pageSize: pageSize, keyStride: keyStride, valueStride: valueStride)
        return 4 + cap * (keyStride + valueStride)
    }

    func innerCapacity(pageSize: Int) -> Int {
        BTree.innerCapacity(pageSize: pageSize, keyStride: keyStride)
    }
    func leafCapacity(pageSize: Int) -> Int {
        BTree.leafCapacity(pageSize: pageSize, keyStride: keyStride, valueStride: valueStride)
    }

    // MARK: - Node views

    /// Read-only view of the 4-byte `{ level, count }` header that every
    /// node page begins with.
    public struct Node {
        public let pointer: UnsafeMutableRawPointer

        public init(pointer: UnsafeMutableRawPointer) { self.pointer = pointer }

        public var level: UInt16 {
            get { pointer.loadUnaligned(as: UInt16.self) }
            nonmutating set { pointer.storeBytes(of: newValue, as: UInt16.self) }
        }

        public var count: UInt16 {
            get { pointer.loadUnaligned(fromByteOffset: 2, as: UInt16.self) }
            nonmutating set { pointer.storeBytes(of: newValue, toByteOffset: 2, as: UInt16.self) }
        }

        public var isLeaf: Bool { level == 0 }
    }

    /// View over an inner-node page: header, then `(capacity - 1)` keys,
    /// then `capacity` child page ids.
    public struct InnerNode {
        public let pointer: UnsafeMutableRawPointer
        public let pageSize: Int
        public let capacity: Int
        let keysOffset: Int
        let childrenOffset: Int
        let keyStride: Int
        let less: (UnsafeRawPointer, UnsafeRawPointer) -> Bool

        public init(
            pointer: UnsafeMutableRawPointer,
            pageSize: Int,
            keyStride: Int,
            less: @escaping (UnsafeRawPointer, UnsafeRawPointer) -> Bool
        ) {
            self.pointer = pointer
            self.pageSize = pageSize
            self.keyStride = keyStride
            self.less = less
            self.capacity = BTree.innerCapacity(pageSize: pageSize, keyStride: keyStride)
            self.keysOffset = 4
            self.childrenOffset = 4 + (self.capacity - 1) * keyStride
        }

        public var level: UInt16 {
            get { pointer.loadUnaligned(as: UInt16.self) }
            nonmutating set { pointer.storeBytes(of: newValue, as: UInt16.self) }
        }

        public var count: UInt16 {
            get { pointer.loadUnaligned(fromByteOffset: 2, as: UInt16.self) }
            nonmutating set { pointer.storeBytes(of: newValue, toByteOffset: 2, as: UInt16.self) }
        }

        public var isLeaf: Bool { level == 0 }

        /// Pointer to the `index`-th separator key (read-only use).
        func keyPointer(at index: Int) -> UnsafeMutableRawPointer {
            pointer.advanced(by: keysOffset + index * keyStride)
        }

        func setKey(from src: UnsafeRawPointer, at index: Int) {
            memcpy(keyPointer(at: index), src, keyStride)
        }

        public func child(at index: Int) -> UInt64 {
            pointer.loadUnaligned(fromByteOffset: childrenOffset + index * 8, as: UInt64.self)
        }

        func setChild(_ child: UInt64, at index: Int) {
            pointer.storeBytes(of: child, toByteOffset: childrenOffset + index * 8, as: UInt64.self)
        }

        /// Index of the first key not less than `key`; `exists` true on
        /// exact match. Returns `(count - 1, false)` if all separator keys
        /// are < `key`, which is the "rightmost child" fall-through.
        public func lowerBound(_ key: UnsafeRawPointer) -> (index: Int, exists: Bool) {
            let n = Int(count)
            for index in 0..<(n - 1) {
                let k = keyPointer(at: index)
                if less(k, key) { continue }
                return (index, !less(key, k))
            }
            return (n - 1, false)
        }

        /// Insert a separator key + right-child page id. `precondition`-fails
        /// if the key already exists.
        public func insertSplit(key: UnsafeRawPointer, splitPage: UInt64) {
            let (index, exists) = lowerBound(key)
            precondition(!exists, "Cannot insert split. Key already exists.")
            let n = Int(count)
            let length = n - index - 1
            if length > 0 {
                let keysSrc = pointer.advanced(by: keysOffset + index * keyStride)
                let keysDst = pointer.advanced(by: keysOffset + (index + 1) * keyStride)
                memmove(keysDst, keysSrc, length * keyStride)
                let childSrc = pointer.advanced(by: childrenOffset + (index + 1) * 8)
                let childDst = pointer.advanced(by: childrenOffset + (index + 2) * 8)
                memmove(childDst, childSrc, length * 8)
            }
            setKey(from: key, at: index)
            setChild(splitPage, at: index + 1)
            count = UInt16(n + 1)
        }

        /// Split this node into `other`: `other.count = (count + 1) / 2`,
        /// then shrink `count` by that amount, copy keys/children to `other`,
        /// and copy the demoted separator (`keys[count - 1]` after the shrink)
        /// into `separatorOut` (`keyStride` bytes). Caller sets `other.level`.
        public func split(into other: UnsafeMutableRawPointer, separatorOut: UnsafeMutableRawPointer) {
            let newNode = InnerNode(pointer: other, pageSize: pageSize, keyStride: keyStride, less: less)
            let oldCount = Int(count)
            let newCount = (oldCount + 1) / 2
            newNode.count = UInt16(newCount)
            let leftCount = oldCount - newCount
            count = UInt16(leftCount)
            let keysSrc = pointer.advanced(by: keysOffset + leftCount * keyStride)
            let keysDst = other.advanced(by: keysOffset)
            memcpy(keysDst, keysSrc, (newCount - 1) * keyStride)
            let childSrc = pointer.advanced(by: childrenOffset + leftCount * 8)
            let childDst = other.advanced(by: childrenOffset)
            memcpy(childDst, childSrc, newCount * 8)
            memcpy(separatorOut, keyPointer(at: leftCount - 1), keyStride)
        }
    }

    /// View over a leaf-node page: header, then `capacity` keys, then
    /// `capacity` values.
    public struct LeafNode {
        public let pointer: UnsafeMutableRawPointer
        public let pageSize: Int
        public let capacity: Int
        let keysOffset: Int
        let valuesOffset: Int
        let keyStride: Int
        let valueStride: Int
        let less: (UnsafeRawPointer, UnsafeRawPointer) -> Bool

        public init(
            pointer: UnsafeMutableRawPointer,
            pageSize: Int,
            keyStride: Int,
            valueStride: Int,
            less: @escaping (UnsafeRawPointer, UnsafeRawPointer) -> Bool
        ) {
            self.pointer = pointer
            self.pageSize = pageSize
            self.keyStride = keyStride
            self.valueStride = valueStride
            self.less = less
            self.capacity = BTree.leafCapacity(pageSize: pageSize, keyStride: keyStride, valueStride: valueStride)
            self.keysOffset = 4
            self.valuesOffset = 4 + self.capacity * keyStride
        }

        public var level: UInt16 {
            get { pointer.loadUnaligned(as: UInt16.self) }
            nonmutating set { pointer.storeBytes(of: newValue, as: UInt16.self) }
        }

        public var count: UInt16 {
            get { pointer.loadUnaligned(fromByteOffset: 2, as: UInt16.self) }
            nonmutating set { pointer.storeBytes(of: newValue, toByteOffset: 2, as: UInt16.self) }
        }

        public var isLeaf: Bool { level == 0 }

        func keyPointer(at index: Int) -> UnsafeMutableRawPointer {
            pointer.advanced(by: keysOffset + index * keyStride)
        }

        func setKey(from src: UnsafeRawPointer, at index: Int) {
            memcpy(keyPointer(at: index), src, keyStride)
        }

        public func value(at index: Int) -> Value {
            pointer.loadUnaligned(fromByteOffset: valuesOffset + index * valueStride, as: Value.self)
        }

        func setValue(_ value: Value, at index: Int) {
            pointer.storeBytes(of: value, toByteOffset: valuesOffset + index * valueStride, as: Value.self)
        }

        public func lowerBound(_ key: UnsafeRawPointer) -> (index: Int, exists: Bool) {
            let n = Int(count)
            for index in 0..<n {
                let k = keyPointer(at: index)
                if less(k, key) { continue }
                return (index, !less(key, k))
            }
            return (n, false)
        }

        /// Insert (or update) a key/value pair. If `key` is already present
        /// the value is overwritten in place; otherwise the entry is shifted
        /// in. `precondition`-fails on overflow.
        public func insert(_ key: UnsafeRawPointer, _ value: Value) {
            let (index, exists) = lowerBound(key)
            if exists {
                setValue(value, at: index)
                return
            }
            let n = Int(count)
            precondition(index < capacity && n < capacity, "Leaf node is full. Cannot insert another value.")
            let length = n - index
            if length > 0 {
                let keysSrc = pointer.advanced(by: keysOffset + index * keyStride)
                let keysDst = pointer.advanced(by: keysOffset + (index + 1) * keyStride)
                memmove(keysDst, keysSrc, length * keyStride)
                let valSrc = pointer.advanced(by: valuesOffset + index * valueStride)
                let valDst = pointer.advanced(by: valuesOffset + (index + 1) * valueStride)
                memmove(valDst, valSrc, length * valueStride)
            }
            setKey(from: key, at: index)
            setValue(value, at: index)
            count = UInt16(n + 1)
        }

        /// Erase a key. No-op if not present.
        public func erase(_ key: UnsafeRawPointer) {
            let (index, exists) = lowerBound(key)
            if !exists { return }
            let n = Int(count)
            if index + 1 < n {
                let length = n - index
                let keysSrc = pointer.advanced(by: keysOffset + (index + 1) * keyStride)
                let keysDst = pointer.advanced(by: keysOffset + index * keyStride)
                memmove(keysDst, keysSrc, length * keyStride)
                let valSrc = pointer.advanced(by: valuesOffset + (index + 1) * valueStride)
                let valDst = pointer.advanced(by: valuesOffset + index * valueStride)
                memmove(valDst, valSrc, length * valueStride)
            }
            count = UInt16(n - 1)
        }

        /// Split this leaf into `other`: the right half's
        /// `count = self.count / 2`, the left keeps the rest, and the
        /// separator (`keys[count - 1]` of the shrunken left node) is copied
        /// into `separatorOut`. The separator key stays in the left leaf.
        public func split(into other: UnsafeMutableRawPointer, separatorOut: UnsafeMutableRawPointer) {
            let newLeaf = LeafNode(
                pointer: other, pageSize: pageSize,
                keyStride: keyStride, valueStride: valueStride, less: less
            )
            let oldCount = Int(count)
            let newCount = oldCount / 2
            newLeaf.count = UInt16(newCount)
            let leftCount = oldCount - newCount
            count = UInt16(leftCount)
            let keysSrc = pointer.advanced(by: keysOffset + leftCount * keyStride)
            let keysDst = other.advanced(by: keysOffset)
            memcpy(keysDst, keysSrc, newCount * keyStride)
            let valSrc = pointer.advanced(by: valuesOffset + leftCount * valueStride)
            let valDst = other.advanced(by: valuesOffset)
            memcpy(valDst, valSrc, newCount * valueStride)
            memcpy(separatorOut, keyPointer(at: leftCount - 1), keyStride)
        }
    }

    // MARK: - Node-view factories (apply this tree's geometry + comparator)

    func leaf(_ pointer: UnsafeMutableRawPointer) -> LeafNode {
        LeafNode(pointer: pointer, pageSize: bufferManager.pageSize,
                 keyStride: keyStride, valueStride: valueStride, less: less)
    }

    func inner(_ pointer: UnsafeMutableRawPointer) -> InnerNode {
        InnerNode(pointer: pointer, pageSize: bufferManager.pageSize, keyStride: keyStride, less: less)
    }

    // MARK: - State

    public var root: UInt64
    public var maxPageId: UInt64
    public var rootLevel: UInt64 = 0
    private let rootMutex = RWLock()
    private let pageAllocMutex = Mutex()

    private func allocatePageId() -> UInt64 {
        pageAllocMutex.lock()
        defer { pageAllocMutex.unlock() }
        maxPageId += 1
        return maxPageId
    }

    // MARK: - Init

    public init(
        segmentId: UInt16,
        bufferManager: BufferManager,
        keyStride: Int,
        less: @escaping (UnsafeRawPointer, UnsafeRawPointer) -> Bool
    ) {
        let initialRoot = UInt64(segmentId) << 48
        self.root = initialRoot
        self.maxPageId = initialRoot
        self.keyStride = keyStride
        self.valueStride = MemoryLayout<Value>.stride
        self.less = less
        super.init(segmentId: segmentId, bufferManager: bufferManager)
    }

    // MARK: - Lookup

    /// Read-only descent: shared root lock, shared page latches.
    public func lookup(_ key: UnsafeRawPointer) throws -> Value? {
        rootMutex.lockShared()
        defer { rootMutex.unlock() }
        var pageId = root
        while true {
            let page = try PageAccess(manager: bufferManager, pageId: pageId, exclusive: false)
            let header = Node(pointer: page.data)
            if header.isLeaf {
                let leafNode = leaf(page.data)
                let (index, exists) = leafNode.lowerBound(key)
                return exists ? leafNode.value(at: index) : nil
            }
            let innerNode = inner(page.data)
            let (index, _) = innerNode.lowerBound(key)
            pageId = innerNode.child(at: index)
        }
    }

    /// Erase. Descends with shared latches; no rebalancing.
    public func erase(_ key: UnsafeRawPointer) throws {
        rootMutex.lockShared()
        defer { rootMutex.unlock() }
        var pageId = root
        while true {
            let page = try PageAccess(manager: bufferManager, pageId: pageId, exclusive: false)
            let header = Node(pointer: page.data)
            if header.isLeaf {
                let leafNode = leaf(page.data)
                leafNode.erase(key)
                page.setDirty()
                return
            }
            let innerNode = inner(page.data)
            let (index, _) = innerNode.lowerBound(key)
            pageId = innerNode.child(at: index)
        }
    }

    // MARK: - Insert

    /// Public insert. Two-phase: try optimistically with a shared root lock,
    /// retry exclusively if a split would propagate to the root.
    public func insert(_ key: UnsafeRawPointer, _ value: Value) throws {
        if try !_insert(key: key, value: value, rootUniquelyLocked: false) {
            _ = try _insert(key: key, value: value, rootUniquelyLocked: true)
        }
    }

    private func _insert(key: UnsafeRawPointer, value: Value, rootUniquelyLocked: Bool) throws -> Bool {
        if rootUniquelyLocked {
            rootMutex.lockExclusive()
        } else {
            rootMutex.lockShared()
        }
        var rootHeld = true
        defer {
            if rootHeld { rootMutex.unlock() }
        }

        let pageSize = bufferManager.pageSize
        var path: [PageAccess] = []
        path.reserveCapacity(Int(rootLevel) + 1)
        path.append(try PageAccess(manager: bufferManager, pageId: root, exclusive: true))
        var pathIndex = 0

        let innerCap = innerCapacity(pageSize: pageSize)
        let leafCap = leafCapacity(pageSize: pageSize)

        // Scratch separators (keyStride bytes each), reused across the cascade.
        let stride = keyStride
        return try withUnsafeTemporaryAllocation(byteCount: stride * 2, alignment: 1) { scratch -> Bool in
            let separatorBuf = scratch.baseAddress!
            let cascadeBuf = scratch.baseAddress!.advanced(by: stride)

            while true {
                let page = path[path.count - 1]
                let header = Node(pointer: page.data)

                if !header.isLeaf {
                    let innerNode = inner(page.data)
                    let (index, _) = innerNode.lowerBound(key)
                    let childPageId = innerNode.child(at: index)
                    path.append(try PageAccess(manager: bufferManager, pageId: childPageId, exclusive: true))
                    if Int(innerNode.count) < innerCap {
                        pathIndex = path.count - 1
                        for i in 0..<(pathIndex - 1) {
                            path[i].unfix()
                        }
                        if pathIndex > 0 && rootHeld {
                            rootMutex.unlock()
                            rootHeld = false
                        }
                    }
                    continue
                }

                page.setDirty()
                let leafNode = leaf(page.data)
                if Int(leafNode.count) < leafCap {
                    leafNode.insert(key, value)
                    return true
                }

                if !rootUniquelyLocked && pathIndex == 0 {
                    return false
                }

                // Split the leaf.
                let newPage = try PageAccess(manager: bufferManager, pageId: allocatePageId(), exclusive: true)
                let newPageId = newPage.id
                newPage.setDirty()
                let newLeaf = leaf(newPage.data)
                leafNode.split(into: newPage.data, separatorOut: separatorBuf)
                if less(key, separatorBuf) {
                    leafNode.insert(key, value)
                } else {
                    newLeaf.insert(key, value)
                }
                page.unfix()

                // The leaf was the only page in the path → grow the tree.
                if path.count == 1 {
                    let newRootPage = try PageAccess(manager: bufferManager, pageId: allocatePageId(), exclusive: true)
                    newRootPage.setDirty()
                    let newRoot = inner(newRootPage.data)
                    newRoot.level = 1
                    newRoot.count = 2
                    newRoot.setKey(from: separatorBuf, at: 0)
                    newRoot.setChild(page.id, at: 0)
                    newRoot.setChild(newPageId, at: 1)
                    root = newRootPage.id
                    rootLevel += 1
                    return true
                }

                var pathIndexMax = path.count - 2
                var parentPage = path[pathIndexMax]
                parentPage.setDirty()
                var parentNode = inner(parentPage.data)
                let parentLevel = parentNode.level

                if Int(parentNode.count) < innerCap {
                    parentNode.insertSplit(key: separatorBuf, splitPage: newPageId)
                    return true
                }

                // Cascade splits up. `separatorBuf` holds the current separator;
                // `cascadeBuf` receives the demoted separator from each split.
                var currentNewPageId = newPageId
                while pathIndexMax > pathIndex {
                    let newSiblingPage = try PageAccess(manager: bufferManager, pageId: allocatePageId(), exclusive: true)
                    newSiblingPage.setDirty()
                    let newSibling = inner(newSiblingPage.data)

                    // previousSeparator = separatorBuf (the key to reinsert)
                    parentNode.split(into: newSiblingPage.data, separatorOut: cascadeBuf)
                    newSibling.level = parentNode.level

                    if less(separatorBuf, key) {
                        newSibling.insertSplit(key: separatorBuf, splitPage: currentNewPageId)
                    } else {
                        parentNode.insertSplit(key: separatorBuf, splitPage: currentNewPageId)
                    }

                    // The demoted separator becomes the next level's separator.
                    memcpy(separatorBuf, cascadeBuf, stride)
                    currentNewPageId = newSiblingPage.id
                    parentPage.unfix()
                    pathIndexMax -= 1
                    parentPage = path[pathIndexMax]
                    parentNode = inner(parentPage.data)
                }

                if pathIndex > 0 { return true }

                // Splits propagated all the way to the root → grow the tree.
                let newRootPage = try PageAccess(manager: bufferManager, pageId: allocatePageId(), exclusive: true)
                newRootPage.setDirty()
                let newRoot = inner(newRootPage.data)
                newRoot.level = parentLevel + 1
                newRoot.count = 2
                newRoot.setKey(from: separatorBuf, at: 0)
                newRoot.setChild(root, at: 0)
                newRoot.setChild(currentNewPageId, at: 1)
                root = newRootPage.id
                rootLevel += 1
                return true
            }
        }
    }
}
