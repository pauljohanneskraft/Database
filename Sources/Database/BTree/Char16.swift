/// Fixed 16-byte key for `BTree` indexes over `char` columns.
///
/// The byte layout matches `Register`'s `char16` payload exactly: the value's
/// UTF-8 bytes (up to 16) followed by zero padding. Callers that need to match
/// a stored column space-pad the value to the column's declared width *before*
/// constructing the key — `Register.setString` does no space-padding of its
/// own, and neither does this type, so the two stay byte-for-byte identical.
///
/// Ordering is byte-wise unsigned lexicographic over the 16 bytes, the same as
/// `Register.<` for the `char16` kind.
public struct Char16: BitwiseCopyable, Comparable, Sendable, Hashable {
    public var lo: UInt64
    public var hi: UInt64

    public init() {
        self.lo = 0
        self.hi = 0
    }

    /// Encodes `value`'s UTF-8 bytes (first 16, zero-padded). No space-padding;
    /// pad the string to the column width first if matching stored data.
    public init(_ value: String) {
        var storage: (UInt64, UInt64) = (0, 0)
        withUnsafeMutableBytes(of: &storage) { dst in
            var written = 0
            for byte in value.utf8 {
                if written == 16 { break }
                dst[written] = byte
                written &+= 1
            }
        }
        self.lo = storage.0
        self.hi = storage.1
    }

    /// Space-pads `value` to `length` (or truncates), then encodes — matching
    /// how `char` columns are stored on disk and how predicate constants are
    /// built in the planner.
    public static func padded(_ value: String, toLength length: Int) -> Char16 {
        if value.count >= length {
            return Char16(String(value.prefix(length)))
        }
        return Char16(value + String(repeating: " ", count: length - value.count))
    }

    public static func < (lhs: Char16, rhs: Char16) -> Bool {
        var l = (lhs.lo, lhs.hi)
        var r = (rhs.lo, rhs.hi)
        return withUnsafeBytes(of: &l) { lb in
            withUnsafeBytes(of: &r) { rb in
                for i in 0..<16 {
                    if lb[i] != rb[i] { return lb[i] < rb[i] }
                }
                return false
            }
        }
    }
}
