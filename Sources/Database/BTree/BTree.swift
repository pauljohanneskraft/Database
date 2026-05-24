#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported platform: BTree requires a POSIX libc for memmove/memcpy")
#endif

/// In-memory B+-Tree on top of `BufferManager`. Generic over `Key` and
/// `Value`; the page size is a runtime constructor argument (Swift lacks
/// value generics), so capacities are computed once at init from `pageSize`
/// and the strides of `Key`/`Value`. Ordering uses `<` from `Comparable`.
///
/// Concurrency: per-page latches in `BufferFrame` (acquired through
/// `fixPage`/`unfixPage`), a root-level `RWLock` for the `root`/`rootLevel`
/// fields, and a two-phase optimistic `insert` that retries with the root
/// locked exclusively if a split would propagate to the root.
public final class BTree<Key, Value>: Segment, @unchecked Sendable
where Key: BitwiseCopyable & Comparable, Value: BitwiseCopyable {

    // MARK: - Layout

    /// Capacity of an `InnerNode` at the given page size:
    /// `(pageSize - sizeof(Node) + sizeof(Key)) / (sizeof(Key) + sizeof(UInt64))`.
    public static func innerCapacity(pageSize: Int) -> Int {
        let keyStride = MemoryLayout<Key>.stride
        return (pageSize - 4 + keyStride) / (keyStride + 8)
    }

    /// Capacity of a `LeafNode` at the given page size:
    /// `(pageSize - sizeof(Node)) / (sizeof(Key) + sizeof(Value))`.
    public static func leafCapacity(pageSize: Int) -> Int {
        let keyStride = MemoryLayout<Key>.stride
        let valueStride = MemoryLayout<Value>.stride
        return (pageSize - 4) / (keyStride + valueStride)
    }

    /// Byte size occupied by an `InnerNode` at the given page size. Includes
    /// header padding derived from `Key` alignment so the layout is stable
    /// across builds.
    public static func innerNodeSize(pageSize: Int) -> Int {
        let keyAlign = MemoryLayout<Key>.alignment
        let keysOffset = ((4 + keyAlign - 1) / keyAlign) * keyAlign
        let cap = innerCapacity(pageSize: pageSize)
        let endOfKeys = keysOffset + (cap - 1) * MemoryLayout<Key>.stride
        let childrenOffset = ((endOfKeys + 7) / 8) * 8 // children are UInt64 → 8-byte align
        return childrenOffset + cap * 8
    }

    /// Byte size occupied by a `LeafNode` at the given page size.
    public static func leafNodeSize(pageSize: Int) -> Int {
        let keyAlign = MemoryLayout<Key>.alignment
        let valueAlign = MemoryLayout<Value>.alignment
        let keyStride = MemoryLayout<Key>.stride
        let valueStride = MemoryLayout<Value>.stride
        let keysOffset = ((4 + keyAlign - 1) / keyAlign) * keyAlign
        let cap = leafCapacity(pageSize: pageSize)
        let endOfKeys = keysOffset + cap * keyStride
        let valuesOffset = ((endOfKeys + valueAlign - 1) / valueAlign) * valueAlign
        return valuesOffset + cap * valueStride
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

        public init(pointer: UnsafeMutableRawPointer, pageSize: Int) {
            self.pointer = pointer
            self.pageSize = pageSize
            self.capacity = BTree.innerCapacity(pageSize: pageSize)
            self.keyStride = MemoryLayout<Key>.stride
            let keyAlign = MemoryLayout<Key>.alignment
            self.keysOffset = ((4 + keyAlign - 1) / keyAlign) * keyAlign
            let endOfKeys = self.keysOffset + (self.capacity - 1) * self.keyStride
            self.childrenOffset = ((endOfKeys + 7) / 8) * 8
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

        public func key(at index: Int) -> Key {
            pointer.loadUnaligned(fromByteOffset: keysOffset + index * keyStride, as: Key.self)
        }

        func setKey(_ key: Key, at index: Int) {
            pointer.storeBytes(of: key, toByteOffset: keysOffset + index * keyStride, as: Key.self)
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
        public func lowerBound(_ key: Key) -> (index: Int, exists: Bool) {
            let n = Int(count)
            for index in 0..<(n - 1) {
                let k = self.key(at: index)
                if k < key { continue }
                return (index, !(key < k))
            }
            return (n - 1, false)
        }

        /// Insert a separator key + right-child page id. `precondition`-fails
        /// if the key already exists.
        public func insertSplit(key: Key, splitPage: UInt64) {
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
            setKey(key, at: index)
            setChild(splitPage, at: index + 1)
            count = UInt16(n + 1)
        }

        /// Split this node into `other`: `other.count = (count + 1) / 2`,
        /// then shrink `count` by that amount, copy keys/children to `other`,
        /// and return the demoted separator (`keys[count - 1]` after the
        /// shrink). Caller must set `other.level = self.level` afterwards.
        public func split(into other: UnsafeMutableRawPointer) -> Key {
            let newNode = InnerNode(pointer: other, pageSize: pageSize)
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
            return key(at: leftCount - 1)
        }

        public func keysVector() -> [Key] {
            (0..<(Int(count) - 1)).map { key(at: $0) }
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

        public init(pointer: UnsafeMutableRawPointer, pageSize: Int) {
            self.pointer = pointer
            self.pageSize = pageSize
            self.capacity = BTree.leafCapacity(pageSize: pageSize)
            self.keyStride = MemoryLayout<Key>.stride
            self.valueStride = MemoryLayout<Value>.stride
            let keyAlign = MemoryLayout<Key>.alignment
            let valueAlign = MemoryLayout<Value>.alignment
            self.keysOffset = ((4 + keyAlign - 1) / keyAlign) * keyAlign
            let endOfKeys = self.keysOffset + self.capacity * self.keyStride
            self.valuesOffset = ((endOfKeys + valueAlign - 1) / valueAlign) * valueAlign
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

        public func key(at index: Int) -> Key {
            pointer.loadUnaligned(fromByteOffset: keysOffset + index * keyStride, as: Key.self)
        }

        func setKey(_ key: Key, at index: Int) {
            pointer.storeBytes(of: key, toByteOffset: keysOffset + index * keyStride, as: Key.self)
        }

        public func value(at index: Int) -> Value {
            pointer.loadUnaligned(fromByteOffset: valuesOffset + index * valueStride, as: Value.self)
        }

        func setValue(_ value: Value, at index: Int) {
            pointer.storeBytes(of: value, toByteOffset: valuesOffset + index * valueStride, as: Value.self)
        }

        public func lowerBound(_ key: Key) -> (index: Int, exists: Bool) {
            let n = Int(count)
            for index in 0..<n {
                let k = self.key(at: index)
                if k < key { continue }
                return (index, !(key < k))
            }
            return (n, false)
        }

        /// Insert (or update) a key/value pair. If `key` is already present
        /// the value is overwritten in place; otherwise the entry is shifted
        /// in. `precondition`-fails on overflow.
        public func insert(_ key: Key, _ value: Value) {
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
            setKey(key, at: index)
            setValue(value, at: index)
            count = UInt16(n + 1)
        }

        /// Erase a key. No-op if not present. The `memmove` length is one
        /// slot longer than strictly needed — it copies one extra slot of
        /// garbage past the new tail, which is harmless because the live
        /// range is `count - 1`.
        public func erase(_ key: Key) {
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
        /// separator returned is `keys[count - 1]` of the shrunken left
        /// node. The separator key stays in the left leaf — standard
        /// B+-Tree leaf-split behaviour.
        public func split(into other: UnsafeMutableRawPointer) -> Key {
            let newLeaf = LeafNode(pointer: other, pageSize: pageSize)
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
            return key(at: leftCount - 1)
        }

        public func keysVector() -> [Key] {
            (0..<Int(count)).map { key(at: $0) }
        }

        public func valuesVector() -> [Value] {
            (0..<Int(count)).map { value(at: $0) }
        }
    }

    // MARK: - State

    public var root: UInt64
    public var maxPageId: UInt64
    public var rootLevel: UInt64 = 0
    private let rootMutex = RWLock()
    private let pageAllocMutex = Mutex()

    /// Atomically reserve the next page id. The only mutation point for
    /// `maxPageId`; safe to call from concurrent optimistic inserts where the
    /// root latch is held only shared (or already released).
    private func allocatePageId() -> UInt64 {
        pageAllocMutex.lock()
        defer { pageAllocMutex.unlock() }
        maxPageId += 1
        return maxPageId
    }

    // MARK: - Init

    public override init(segmentId: UInt16, bufferManager: BufferManager) {
        let initialRoot = UInt64(segmentId) << 48
        self.root = initialRoot
        self.maxPageId = initialRoot
        super.init(segmentId: segmentId, bufferManager: bufferManager)
    }

    // MARK: - Lookup

    /// Read-only descent: shared root lock, shared page latches, returns
    /// `Value?` (nil when missing).
    public func lookup(_ key: Key) throws -> Value? {
        rootMutex.lockShared()
        defer { rootMutex.unlock() }
        var pageId = root
        while true {
            let page = try PageAccess(manager: bufferManager, pageId: pageId, exclusive: false)
            let header = Node(pointer: page.data)
            if header.isLeaf {
                let leaf = LeafNode(pointer: page.data, pageSize: bufferManager.pageSize)
                let (index, exists) = leaf.lowerBound(key)
                return exists ? leaf.value(at: index) : nil
            }
            let inner = InnerNode(pointer: page.data, pageSize: bufferManager.pageSize)
            let (index, _) = inner.lowerBound(key)
            pageId = inner.child(at: index)
            // page is unfixed by deinit at next loop iteration (when it is
            // overwritten) — `PageAccess` is RAII.
        }
    }

    /// Erase. Descends with shared latches; no rebalancing.
    public func erase(_ key: Key) throws {
        rootMutex.lockShared()
        defer { rootMutex.unlock() }
        var pageId = root
        while true {
            let page = try PageAccess(manager: bufferManager, pageId: pageId, exclusive: false)
            let header = Node(pointer: page.data)
            if header.isLeaf {
                let leaf = LeafNode(pointer: page.data, pageSize: bufferManager.pageSize)
                leaf.erase(key)
                page.setDirty()
                return
            }
            let inner = InnerNode(pointer: page.data, pageSize: bufferManager.pageSize)
            let (index, _) = inner.lowerBound(key)
            pageId = inner.child(at: index)
        }
    }

    // MARK: - Insert

    /// Public insert. Two-phase: try optimistically with a shared root lock,
    /// retry exclusively if a split would propagate to the root.
    public func insert(_ key: Key, _ value: Value) throws {
        if try !_insert(key: key, value: value, rootUniquelyLocked: false) {
            _ = try _insert(key: key, value: value, rootUniquelyLocked: true)
        }
    }

    /// Insert worker. Returns `false` only in the optimistic-phase case where
    /// a leaf split would propagate to the root and the root was only locked
    /// shared — caller retries with `rootUniquelyLocked = true`.
    private func _insert(key: Key, value: Value, rootUniquelyLocked: Bool) throws -> Bool {
        if rootUniquelyLocked {
            rootMutex.lockExclusive()
        } else {
            rootMutex.lockShared()
        }
        // Tracks whether the root mutex is still held. The latch is released
        // early once we crab past a safe ancestor; `defer` checks the flag at
        // exit so it doesn't double-unlock.
        var rootHeld = true
        defer {
            if rootHeld { rootMutex.unlock() }
        }

        let pageSize = bufferManager.pageSize
        var path: [PageAccess] = []
        path.reserveCapacity(Int(rootLevel) + 1)
        path.append(try PageAccess(manager: bufferManager, pageId: root, exclusive: true))
        var pathIndex = 0

        let innerCap = BTree.innerCapacity(pageSize: pageSize)
        let leafCap = BTree.leafCapacity(pageSize: pageSize)

        while true {
            let page = path[path.count - 1]
            let header = Node(pointer: page.data)

            if !header.isLeaf {
                let inner = InnerNode(pointer: page.data, pageSize: pageSize)
                let (index, _) = inner.lowerBound(key)
                let childPageId = inner.child(at: index)
                path.append(try PageAccess(manager: bufferManager, pageId: childPageId, exclusive: true))
                if Int(inner.count) < innerCap {
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
            let leaf = LeafNode(pointer: page.data, pageSize: pageSize)
            if Int(leaf.count) < leafCap {
                leaf.insert(key, value)
                return true
            }

            // Leaf is full and the optimistic phase reached the root with no
            // safe ancestor → bail out and let the caller retry with the
            // root locked exclusively.
            if !rootUniquelyLocked && pathIndex == 0 {
                return false
            }

            // Split the leaf.
            let newPage = try PageAccess(manager: bufferManager, pageId: allocatePageId(), exclusive: true)
            let newPageId = newPage.id
            newPage.setDirty()
            let newLeaf = LeafNode(pointer: newPage.data, pageSize: pageSize)
            let separatorKey = leaf.split(into: newPage.data)
            if key < separatorKey {
                leaf.insert(key, value)
            } else {
                newLeaf.insert(key, value)
            }
            page.unfix()

            // Special case: the leaf was the only page in the path → it is
            // the root, and we need to grow the tree by one level.
            if path.count == 1 {
                let newRootPage = try PageAccess(manager: bufferManager, pageId: allocatePageId(), exclusive: true)
                newRootPage.setDirty()
                let newRoot = InnerNode(pointer: newRootPage.data, pageSize: pageSize)
                newRoot.level = 1
                newRoot.count = 2
                newRoot.setKey(separatorKey, at: 0)
                newRoot.setChild(page.id, at: 0)
                newRoot.setChild(newPageId, at: 1)
                root = newRootPage.id
                rootLevel += 1
                return true
            }

            var pathIndexMax = path.count - 2
            var parentPage = path[pathIndexMax]
            parentPage.setDirty()
            var parentNode = InnerNode(pointer: parentPage.data, pageSize: pageSize)
            let parentLevel = parentNode.level

            if Int(parentNode.count) < innerCap {
                parentNode.insertSplit(key: separatorKey, splitPage: newPageId)
                return true
            }

            // Cascade splits up. Each iteration splits `parentNode`, hands
            // the previous separator+child to whichever side `key` belongs
            // on, and walks one level higher in the path.
            var currentSeparator = separatorKey
            var currentNewPageId = newPageId
            while pathIndexMax > pathIndex {
                let newSiblingPage = try PageAccess(manager: bufferManager, pageId: allocatePageId(), exclusive: true)
                newSiblingPage.setDirty()
                let newSibling = InnerNode(pointer: newSiblingPage.data, pageSize: pageSize)

                let previousSeparator = currentSeparator
                currentSeparator = parentNode.split(into: newSiblingPage.data)
                newSibling.level = parentNode.level

                if previousSeparator < key {
                    newSibling.insertSplit(key: previousSeparator, splitPage: currentNewPageId)
                } else {
                    parentNode.insertSplit(key: previousSeparator, splitPage: currentNewPageId)
                }

                currentNewPageId = newSiblingPage.id
                parentPage.unfix()
                pathIndexMax -= 1
                parentPage = path[pathIndexMax]
                parentNode = InnerNode(pointer: parentPage.data, pageSize: pageSize)
            }

            // Reached a safe ancestor mid-cascade → done.
            if pathIndex > 0 { return true }

            // Splits propagated all the way to the root → grow the tree.
            let newRootPage = try PageAccess(manager: bufferManager, pageId: allocatePageId(), exclusive: true)
            newRootPage.setDirty()
            let newRoot = InnerNode(pointer: newRootPage.data, pageSize: pageSize)
            newRoot.level = parentLevel + 1
            newRoot.count = 2
            newRoot.setKey(currentSeparator, at: 0)
            newRoot.setChild(root, at: 0)
            newRoot.setChild(currentNewPageId, at: 1)
            root = newRootPage.id
            rootLevel += 1
            return true
        }
    }
}
