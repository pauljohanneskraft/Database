/// Lookup-style index scan. Emits zero rows if the key is absent or one row
/// containing the looked-up value as the sole output register.
///
/// The lookup is captured as a `resolve` closure (it binds the tree, the
/// encoded key, and a decoder from the tree's value to a `Register`). This
/// keeps `IndexScan` independent of the byte-keyed `BTree`'s generics — callers
/// using a `BTree<UInt64>` typically resolve to `Register.from(int:)` of the
/// TID raw value.
public final class IndexScan: Operator {
    private let resolve: () throws -> Register?

    private var emitted = false
    private var output: [Register] = []

    public init(resolve: @escaping () throws -> Register?) {
        self.resolve = resolve
    }

    public func open() {
        emitted = false
        output = [Register()]
    }

    public func next() -> Bool {
        if emitted { return false }
        emitted = true
        let value: Register?
        do {
            value = try resolve()
        } catch {
            return false
        }
        guard let v = value else { return false }
        output[0].assign(from: v)
        return true
    }

    public func close() {
        output.removeAll()
        emitted = false
    }

    public func getOutput() -> [Register] { output }
}
