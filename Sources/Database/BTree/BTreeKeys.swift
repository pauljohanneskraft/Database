#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// Key encoders / comparators and typed conveniences for the byte-keyed
/// `BTree`. The tree itself is agnostic to key meaning — it stores `keyStride`
/// raw bytes and orders them with the `less` closure handed to its initializer.
/// These helpers package the three key flavours the engine uses: `Int64`
/// (numeric), `UInt64` (numeric, the tests' key), and char (lexicographic over
/// the column's declared width, content NUL-filled — matching `Register`'s
/// content/NUL semantics from the storage layer).

extension BTree {
    // MARK: - UInt64 keys (numeric)

    static func uint64Keyed(segmentId: UInt16, bufferManager: BufferManager) -> BTree {
        BTree(segmentId: segmentId, bufferManager: bufferManager, keyStride: 8) { a, b in
            a.loadUnaligned(as: UInt64.self) < b.loadUnaligned(as: UInt64.self)
        }
    }

    func insert(_ key: UInt64, _ value: Value) throws {
        var k = key
        try withUnsafeBytes(of: &k) { try insert($0.baseAddress!, value) }
    }

    func lookup(_ key: UInt64) throws -> Value? {
        var k = key
        return try withUnsafeBytes(of: &k) { try lookup($0.baseAddress!) }
    }

    func erase(_ key: UInt64) throws {
        var k = key
        try withUnsafeBytes(of: &k) { try erase($0.baseAddress!) }
    }

    // MARK: - Int64 keys (numeric)

    static func int64Keyed(segmentId: UInt16, bufferManager: BufferManager) -> BTree {
        BTree(segmentId: segmentId, bufferManager: bufferManager, keyStride: 8) { a, b in
            a.loadUnaligned(as: Int64.self) < b.loadUnaligned(as: Int64.self)
        }
    }

    func insert(_ key: Int64, _ value: Value) throws {
        var k = key
        try withUnsafeBytes(of: &k) { try insert($0.baseAddress!, value) }
    }

    func lookup(_ key: Int64) throws -> Value? {
        var k = key
        return try withUnsafeBytes(of: &k) { try lookup($0.baseAddress!) }
    }

    func erase(_ key: Int64) throws {
        var k = key
        try withUnsafeBytes(of: &k) { try erase($0.baseAddress!) }
    }

    // MARK: - Char keys (lexicographic, fixed `width`)

    /// A char-keyed tree of fixed width `width` bytes. Keys compare as unsigned
    /// lexicographic byte strings — consistent with `Register`'s content order,
    /// since the NUL fill byte (`0x00`) sorts below any content byte.
    static func charKeyed(segmentId: UInt16, bufferManager: BufferManager, width: Int) -> BTree {
        BTree(segmentId: segmentId, bufferManager: bufferManager, keyStride: width) { a, b in
            let r = memcmp(a, b, width)
            return r < 0
        }
    }

    /// Encode a string to a `width`-byte key: UTF-8 content, truncated past
    /// `width`, NUL-filled to `width`.
    static func charKey(_ s: String, width: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width)
        var i = 0
        for byte in s.utf8 {
            if i == width { break }
            bytes[i] = byte
            i += 1
        }
        return bytes
    }

    func insert(charKey s: String, width: Int, _ value: Value) throws {
        let bytes = BTree.charKey(s, width: width)
        try bytes.withUnsafeBytes { try insert($0.baseAddress!, value) }
    }

    func lookup(charKey s: String, width: Int) throws -> Value? {
        let bytes = BTree.charKey(s, width: width)
        return try bytes.withUnsafeBytes { try lookup($0.baseAddress!) }
    }
}
