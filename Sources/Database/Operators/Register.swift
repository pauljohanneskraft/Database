/// A register represents a single attribute value passed between operators.
/// Tagged union over `Int64`, a variable-length char string, `Double`, or
/// `Bool`.
///
/// Reference type: operators publish stable register identities once during
/// `open()`; subsequent `next()` calls mutate the underlying value in place
/// (or reseat which `Register` reference appears at a given output slot).
public final class Register: @unchecked Sendable {
    public enum Kind: UInt8, Sendable {
        case int64
        /// A char column's value. Historically a fixed 16-byte payload; now a
        /// variable-length UTF-8 content buffer (`stringStorage`) holding only
        /// the meaningful bytes — no trailing pad. The declared `CHAR(n)` width
        /// is a disk/wire concern, not the register's.
        case char16
        case double
        case bool
    }

    public private(set) var kind: Kind

    /// Inline scalar storage. `int64` / `double` / `bool` use only `storage.0`
    /// (bit-cast for double, `0`/`1` for bool). Unused by `char16`.
    private var storage: (UInt64, UInt64)

    /// Variable-length UTF-8 content for `char16` (no trailing pad). The buffer
    /// keeps its capacity across `setString` calls so per-row mutation in the
    /// iterator model does not reallocate once it stabilises at the widest
    /// content seen.
    private var stringStorage: [UInt8] = []

    public init() {
        self.kind = .int64
        self.storage = (0, 0)
    }

    public static func from(int value: Int64) -> Register {
        let r = Register()
        r.setInt(value)
        return r
    }

    public static func from(string value: String) -> Register {
        let r = Register()
        r.setString(value)
        return r
    }

    public static func from(double value: Double) -> Register {
        let r = Register()
        r.setDouble(value)
        return r
    }

    public static func from(bool value: Bool) -> Register {
        let r = Register()
        r.setBool(value)
        return r
    }

    public func setInt(_ value: Int64) {
        kind = .int64
        storage = (UInt64(bitPattern: value), 0)
    }

    /// Stores `value`'s UTF-8 content, stopping at the first NUL (`0x00`) —
    /// the on-disk fill byte, so a value read back from a fixed-width field
    /// keeps only its content. No length cap and no trailing pad; the buffer's
    /// capacity is reused to avoid per-row allocation.
    public func setString(_ value: String) {
        kind = .char16
        stringStorage.removeAll(keepingCapacity: true)
        for byte in value.utf8 {
            if byte == 0 { break }
            stringStorage.append(byte)
        }
    }

    public func setDouble(_ value: Double) {
        kind = .double
        storage = (value.bitPattern, 0)
    }

    public func setBool(_ value: Bool) {
        kind = .bool
        storage = (value ? 1 : 0, 0)
    }

    public var asInt: Int64 {
        Int64(bitPattern: storage.0)
    }

    public var asString: String {
        String(decoding: stringStorage, as: UTF8.self)
    }

    public var asDouble: Double {
        Double(bitPattern: storage.0)
    }

    public var asBool: Bool {
        storage.0 != 0
    }

    public func copy() -> Register {
        let r = Register()
        r.kind = kind
        r.storage = storage
        r.stringStorage = stringStorage
        return r
    }

    /// Overwrites this register's value with `other`'s. Lets source operators
    /// reseat values without re-encoding through the typed setters.
    public func assign(from other: Register) {
        self.kind = other.kind
        self.storage = other.storage
        self.stringStorage = other.stringStorage
    }
}

extension Register: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        switch kind {
        case .int64, .double, .bool:
            hasher.combine(storage.0)
        case .char16:
            hasher.combine(stringStorage)
        }
    }

    public static func == (lhs: Register, rhs: Register) -> Bool {
        if lhs.kind != rhs.kind { return false }
        switch lhs.kind {
        case .int64, .bool:
            return lhs.storage.0 == rhs.storage.0
        case .double:
            // NaN-aware equality: bit-pattern compare keeps NaN distinct from
            // itself, matching IEEE-754 semantics that the operators rely on.
            return lhs.asDouble == rhs.asDouble
        case .char16:
            return lhs.stringStorage == rhs.stringStorage
        }
    }
}

extension Register: Comparable {
    /// Ordering between registers of the same kind. Asserts that both sides
    /// have matching kinds.
    public static func < (lhs: Register, rhs: Register) -> Bool {
        assert(lhs.kind == rhs.kind, "Register comparison across mismatched kinds")
        switch lhs.kind {
        case .int64:
            return lhs.asInt < rhs.asInt
        case .double:
            return lhs.asDouble < rhs.asDouble
        case .bool:
            // false < true.
            return !lhs.asBool && rhs.asBool
        case .char16:
            // Unsigned lexicographic over content bytes; the shorter content
            // sorts first on a shared prefix (matches NUL-filled byte order,
            // since the fill byte 0x00 is below any content byte).
            let l = lhs.stringStorage
            let r = rhs.stringStorage
            let n = Swift.min(l.count, r.count)
            var i = 0
            while i < n {
                if l[i] != r[i] { return l[i] < r[i] }
                i += 1
            }
            return l.count < r.count
        }
    }
}
