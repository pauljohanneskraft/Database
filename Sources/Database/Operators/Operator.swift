/// The iterator-model operator interface.
///
/// Output is passed out-of-line: callers retrieve the operator's output
/// register layout via `getOutput()` (typically once after `open()`), then
/// consume each tuple by calling `next()` and dereferencing the registers.
public protocol Operator: AnyObject {
    /// Initialises the operator and any inputs.
    func open()

    /// Generates the next tuple. Returns `true` while tuples are available.
    func next() -> Bool

    /// Tears down the operator and any inputs.
    func close()

    /// Returns this operator's output register layout. Each entry corresponds
    /// to one attribute. The register identities are stable across `next()`
    /// calls within a single `open()` cycle.
    func getOutput() -> [Register]
}

/// Base for operators with a single input.
open class UnaryOperator {
    public let input: any Operator
    public init(input: any Operator) { self.input = input }
}

/// Base for operators with two inputs.
open class BinaryOperator {
    public let inputLeft: any Operator
    public let inputRight: any Operator
    public init(inputLeft: any Operator, inputRight: any Operator) {
        self.inputLeft = inputLeft
        self.inputRight = inputRight
    }
}

/// A reference-typed text sink usable as an `inout`-free destination for
/// `Print`. Tests read `contents` after consuming the operator.
public final class TextOutput: TextOutputStream {
    public private(set) var contents: String = ""
    public init() {}
    public func write(_ string: String) {
        contents.append(string)
    }
}

/// Snapshots the values of a row of registers (`copy()` per-element).
@inline(__always)
internal func snapshot(_ row: [Register]) -> [Register] {
    row.map { $0.copy() }
}
