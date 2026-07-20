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

    /// SQL NULL. Scoped narrowly to the one place the engine needs it today:
    /// `MIN`/`MAX` over an ungrouped, empty input (see `HashAggregation`). No
    /// column is nullable, and no predicate does three-valued NULL logic —
    /// this bit only has to behave correctly for grouping/dedup (`==`/`hash`,
    /// where two NULLs compare equal, matching SQL's `IS NOT DISTINCT FROM`)
    /// and for `Print` output. `kind` is retained for a null register (it's
    /// still meaningful metadata) but never consulted for a null value.
    public private(set) var isNull: Bool = false

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

    /// A NULL register. `kind` is retained as metadata (e.g. for diagnostics)
    /// but never consulted while `isNull` is set.
    public static func null(kind: Kind) -> Register {
        let r = Register()
        r.kind = kind
        r.isNull = true
        return r
    }

    public func setInt(_ value: Int64) {
        kind = .int64
        isNull = false
        storage = (UInt64(bitPattern: value), 0)
    }

    /// Stores `value`'s UTF-8 content, stopping at the first NUL (`0x00`) —
    /// the on-disk fill byte, so a value read back from a fixed-width field
    /// keeps only its content. No length cap and no trailing pad; the buffer's
    /// capacity is reused to avoid per-row allocation.
    public func setString(_ value: String) {
        kind = .char16
        isNull = false
        stringStorage.removeAll(keepingCapacity: true)
        for byte in value.utf8 {
            if byte == 0 { break }
            stringStorage.append(byte)
        }
    }

    public func setDouble(_ value: Double) {
        kind = .double
        isNull = false
        storage = (value.bitPattern, 0)
    }

    public func setBool(_ value: Bool) {
        kind = .bool
        isNull = false
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
        r.isNull = isNull
        r.storage = storage
        r.stringStorage = stringStorage
        return r
    }

    /// Overwrites this register's value with `other`'s. Lets source operators
    /// reseat values without re-encoding through the typed setters.
    public func assign(from other: Register) {
        self.kind = other.kind
        self.isNull = other.isNull
        self.storage = other.storage
        self.stringStorage = other.stringStorage
    }

    /// Overwrites this register's value with a tuple-decoder result, routing
    /// to the matching typed setter.
    func assign(from value: DecodedTupleValue) {
        switch value {
        case .int(let v): setInt(v)
        case .string(let v): setString(v)
        case .double(let v): setDouble(v)
        case .bool(let v): setBool(v)
        }
    }
}

extension Register: Hashable {
    public func hash(into hasher: inout Hasher) {
        // NULLs all hash alike, ignoring `kind` — grouping/dedup treats every
        // NULL as interchangeable (SQL's `IS NOT DISTINCT FROM`), unlike `=`.
        guard !isNull else {
            hasher.combine(0 as UInt8)
            return
        }
        hasher.combine(kind)
        switch kind {
        case .int64, .bool:
            hasher.combine(storage.0)
        case .double:
            // Hash the value, not the bit pattern — `==` treats `0.0` and
            // `-0.0` as equal (IEEE-754), so they must hash equally too.
            hasher.combine(asDouble)
        case .char16:
            hasher.combine(stringStorage)
        }
    }

    public static func == (lhs: Register, rhs: Register) -> Bool {
        // Two NULLs compare equal here (grouping/dedup identity), even
        // though ordinary SQL `=` semantics would say NULL = NULL is unknown
        // — this engine has no three-valued predicate logic, and this `==`
        // is only ever used for GROUP BY/DISTINCT/JOIN key identity.
        if lhs.isNull || rhs.isNull { return lhs.isNull && rhs.isNull }
        if lhs.kind != rhs.kind { return false }
        switch lhs.kind {
        case .int64, .bool:
            return lhs.storage.0 == rhs.storage.0
        case .double:
            // Plain IEEE-754 equality: NaN != NaN, unlike a bit-pattern
            // compare. Kept this way because ordinary predicates (`=`, `<`)
            // need correct IEEE-754 behavior; NaN is rejected at insert time
            // instead (see `Database.insert`) so it never reaches here.
            return lhs.asDouble == rhs.asDouble
        case .char16:
            return lhs.stringStorage == rhs.stringStorage
        }
    }
}

extension Register: Comparable {
    /// Ordering between registers of the same kind. Asserts that both sides
    /// have matching kinds (NULLs excepted — they never trip the assert).
    public static func < (lhs: Register, rhs: Register) -> Bool {
        // NULLS FIRST, matching common SQL ascending-sort convention. Also
        // sidesteps the kind assert below: a NULL register's `kind` need not
        // match the other side's.
        if lhs.isNull || rhs.isNull { return lhs.isNull && !rhs.isNull }
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
