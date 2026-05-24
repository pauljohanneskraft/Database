/// Lookup-style index scan over a `BTree<Key, Value>`. Given a single key,
/// emits zero rows if the key is absent or one row containing the looked-up
/// value as the sole output register.
///
/// `Value` is converted to a `Register` via the supplied `decode` closure —
/// callers using a `BTree<UInt64, UInt64>` typically pass
/// `{ Register.from(int: Int64(bitPattern: $0)) }` to emit the TID raw value.
public final class IndexScan<Key, Value>: Operator
where Key: BitwiseCopyable & Comparable, Value: BitwiseCopyable {
    public let tree: BTree<Key, Value>
    public let key: Key
    private let decode: (Value) -> Register

    private var emitted = false
    private var output: [Register] = []

    public init(
        tree: BTree<Key, Value>,
        key: Key,
        decode: @escaping (Value) -> Register
    ) {
        self.tree = tree
        self.key = key
        self.decode = decode
    }

    public func open() {
        emitted = false
        output = [Register()]
    }

    public func next() -> Bool {
        if emitted { return false }
        emitted = true
        let value: Value?
        do {
            value = try tree.lookup(key)
        } catch {
            return false
        }
        guard let v = value else { return false }
        let r = decode(v)
        output[0].assign(from: r)
        return true
    }

    public func close() {
        output.removeAll()
        emitted = false
    }

    public func getOutput() -> [Register] { output }
}
