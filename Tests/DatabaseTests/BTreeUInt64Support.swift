import Foundation
@testable import Database

/// Test-only typed conveniences for a `UInt64`-keyed `BTree`.
///
/// The production tree is byte-keyed (runtime `keyStride` + a `less` closure,
/// see `BTree`/`BTreeKeys`). These shims re-create the old `BTree<UInt64, …>`
/// surface the B+-tree tests are written against — fixing the key geometry at
/// 8-byte little-endian `UInt64` — so the tests read at the key's natural type
/// without leaking a typed-key API into the shipping module.

private func uint64Less(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer) -> Bool {
    a.loadUnaligned(as: UInt64.self) < b.loadUnaligned(as: UInt64.self)
}

extension BTree where Value == UInt64 {
    /// A `UInt64`-keyed tree with the default 8-byte numeric geometry.
    convenience init(segmentId: UInt16, bufferManager: BufferManager) {
        self.init(segmentId: segmentId, bufferManager: bufferManager, keyStride: 8, less: uint64Less)
    }
}

extension BTree.LeafNode where Value == UInt64 {
    init(pointer: UnsafeMutableRawPointer, pageSize: Int) {
        self.init(pointer: pointer, pageSize: pageSize, keyStride: 8, valueStride: 8, less: uint64Less)
    }

    func insert(_ key: UInt64, _ value: UInt64) {
        var k = key
        withUnsafeBytes(of: &k) { insert($0.baseAddress!, value) }
    }

    func keysVector() -> [UInt64] {
        (0..<Int(count)).map { keyPointer(at: $0).loadUnaligned(as: UInt64.self) }
    }

    func valuesVector() -> [UInt64] {
        (0..<Int(count)).map { value(at: $0) }
    }

    /// Split into `other`, returning the demoted separator key.
    func split(into other: UnsafeMutableRawPointer) -> UInt64 {
        var separator: UInt64 = 0
        withUnsafeMutableBytes(of: &separator) { split(into: other, separatorOut: $0.baseAddress!) }
        return separator
    }
}
