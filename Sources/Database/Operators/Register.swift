/// A register represents a single attribute value passed between operators.
/// Tagged union over `Int64`, a fixed 16-byte string, `Double`, or `Bool`.
///
/// Reference type: operators publish stable register identities once during
/// `open()`; subsequent `next()` calls mutate the underlying value in place
/// (or reseat which `Register` reference appears at a given output slot).
public final class Register: @unchecked Sendable {
    public enum Kind: UInt8, Sendable {
        case int64
        case char16
        case double
        case bool
    }

    public private(set) var kind: Kind

    /// 16 bytes of inline storage. `char16` uses both halves; `int64`,
    /// `double`, and `bool` use only `storage.0` (bit-cast for double,
    /// `0`/`1` for bool).
    private var storage: (UInt64, UInt64)

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

    /// Copies up to 16 bytes from `value`'s UTF-8 representation. Bytes past
    /// the end of `value` (when shorter than 16) are zero. Tests always pass
    /// strings of exactly 16 bytes.
    public func setString(_ value: String) {
        kind = .char16
        storage = (0, 0)
        withUnsafeMutableBytes(of: &storage) { dst in
            var written = 0
            for byte in value.utf8 {
                if written == 16 { break }
                dst[written] = byte
                written &+= 1
            }
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
        withUnsafeBytes(of: storage) { raw in
            String(decoding: raw, as: UTF8.self)
        }
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
        return r
    }

    /// Overwrites this register's value with `other`'s. Lets source operators
    /// reseat values without re-encoding through the typed setters.
    public func assign(from other: Register) {
        self.kind = other.kind
        self.storage = other.storage
    }
}

extension Register: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        switch kind {
        case .int64, .double, .bool:
            hasher.combine(storage.0)
        case .char16:
            hasher.combine(storage.0)
            hasher.combine(storage.1)
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
            return lhs.storage.0 == rhs.storage.0 && lhs.storage.1 == rhs.storage.1
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
            return withUnsafeBytes(of: lhs.storage) { l in
                withUnsafeBytes(of: rhs.storage) { r in
                    let lb = l.bindMemory(to: UInt8.self)
                    let rb = r.bindMemory(to: UInt8.self)
                    for i in 0..<16 {
                        if lb[i] != rb[i] { return lb[i] < rb[i] }
                    }
                    return false
                }
            }
        }
    }
}
