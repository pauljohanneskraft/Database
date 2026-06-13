// Concrete iterator-model operators.

// MARK: - Print

/// Prints all tuples from its input into the given `TextOutput`. Tuples are
/// separated by `\n` and attributes by single commas. Calling `next()`
/// prints the next tuple.
public final class Print: UnaryOperator, Operator {
    private let stream: TextOutput

    public init(input: any Operator, stream: TextOutput) {
        self.stream = stream
        super.init(input: input)
    }

    public func open() {
        input.open()
    }

    public func next() -> Bool {
        guard input.next() else { return false }
        let row = input.getOutput()
        for (index, value) in row.enumerated() {
            if index > 0 { stream.write(",") }
            switch value.kind {
            case .int64:
                stream.write(String(value.asInt))
            case .char16:
                stream.write(value.asString)
            case .double:
                stream.write(String(value.asDouble))
            case .bool:
                stream.write(value.asBool ? "true" : "false")
            }
        }
        stream.write("\n")
        return true
    }

    public func close() {
        input.close()
    }

    public func getOutput() -> [Register] { [] }
}

// MARK: - Projection

/// Generates tuples from the input with only a subset of their attributes.
public final class Projection: UnaryOperator, Operator {
    private let attrIndexes: [Int]
    private var output: [Register]

    public init(input: any Operator, attrIndexes: [Int]) {
        self.attrIndexes = attrIndexes
        self.output = Array(repeating: Register(), count: attrIndexes.count)
        super.init(input: input)
    }

    public func open() {
        input.open()
    }

    public func next() -> Bool {
        guard input.next() else { return false }
        let row = input.getOutput()
        for (i, attr) in attrIndexes.enumerated() {
            output[i] = row[attr]
        }
        return true
    }

    public func close() {
        input.close()
        output.removeAll()
    }

    public func getOutput() -> [Register] { output }
}

// MARK: - Select

/// Filters tuples by a given predicate.
public final class Select: UnaryOperator, Operator {
    public enum PredicateType: Sendable {
        case eq, ne, lt, le, gt, ge
    }

    /// `tuple[attrIndex] P constant` where `P` is `predicateType`.
    public struct PredicateAttributeInt64: Sendable {
        public let attrIndex: Int
        public let constant: Int64
        public let predicateType: PredicateType
        public init(attrIndex: Int, constant: Int64, predicateType: PredicateType) {
            self.attrIndex = attrIndex
            self.constant = constant
            self.predicateType = predicateType
        }
    }

    /// `tuple[attrIndex] P constant` where `constant` is a 16-byte string.
    public struct PredicateAttributeChar16: Sendable {
        public let attrIndex: Int
        public let constant: String
        public let predicateType: PredicateType
        public init(attrIndex: Int, constant: String, predicateType: PredicateType) {
            self.attrIndex = attrIndex
            self.constant = constant
            self.predicateType = predicateType
        }
    }

    /// `tuple[attrIndex] P constant` where `constant` is a `Double`.
    public struct PredicateAttributeDouble: Sendable {
        public let attrIndex: Int
        public let constant: Double
        public let predicateType: PredicateType
        public init(attrIndex: Int, constant: Double, predicateType: PredicateType) {
            self.attrIndex = attrIndex
            self.constant = constant
            self.predicateType = predicateType
        }
    }

    /// `tuple[attrIndex] P constant` where `constant` is a `Bool`. Only `eq`
    /// and `ne` make sense; the ordering variants treat `false < true`.
    public struct PredicateAttributeBool: Sendable {
        public let attrIndex: Int
        public let constant: Bool
        public let predicateType: PredicateType
        public init(attrIndex: Int, constant: Bool, predicateType: PredicateType) {
            self.attrIndex = attrIndex
            self.constant = constant
            self.predicateType = predicateType
        }
    }

    /// `tuple[leftIndex] P tuple[rightIndex]`.
    public struct PredicateAttributeAttribute: Sendable {
        public let attrLeftIndex: Int
        public let attrRightIndex: Int
        public let predicateType: PredicateType
        public init(attrLeftIndex: Int, attrRightIndex: Int, predicateType: PredicateType) {
            self.attrLeftIndex = attrLeftIndex
            self.attrRightIndex = attrRightIndex
            self.predicateType = predicateType
        }
    }

    private let select: ([Register]) -> Bool

    public init(input: any Operator, predicate: PredicateAttributeInt64) {
        let attrIndex = predicate.attrIndex
        let constant = predicate.constant
        let p = predicate.predicateType
        self.select = { row in
            let lhs = row[attrIndex].asInt
            switch p {
            case .eq: return lhs == constant
            case .ne: return lhs != constant
            case .lt: return lhs < constant
            case .le: return lhs <= constant
            case .gt: return lhs > constant
            case .ge: return lhs >= constant
            }
        }
        super.init(input: input)
    }

    public init(input: any Operator, predicate: PredicateAttributeChar16) {
        let attrIndex = predicate.attrIndex
        let constant = predicate.constant
        let p = predicate.predicateType
        // Encode the constant once into a Register to leverage 16-byte equality
        // and lex ordering identical to the rest of the system.
        let constReg = Register.from(string: constant)
        self.select = { row in
            let lhs = row[attrIndex]
            switch p {
            case .eq: return lhs == constReg
            case .ne: return lhs != constReg
            case .lt: return lhs < constReg
            case .le: return lhs <= constReg
            case .gt: return lhs > constReg
            case .ge: return lhs >= constReg
            }
        }
        super.init(input: input)
    }

    public init(input: any Operator, predicate: PredicateAttributeDouble) {
        let attrIndex = predicate.attrIndex
        let constant = predicate.constant
        let p = predicate.predicateType
        self.select = { row in
            let lhs = row[attrIndex].asDouble
            switch p {
            case .eq: return lhs == constant
            case .ne: return lhs != constant
            case .lt: return lhs < constant
            case .le: return lhs <= constant
            case .gt: return lhs > constant
            case .ge: return lhs >= constant
            }
        }
        super.init(input: input)
    }

    public init(input: any Operator, predicate: PredicateAttributeBool) {
        let attrIndex = predicate.attrIndex
        let constant = predicate.constant
        let p = predicate.predicateType
        self.select = { row in
            let lhs = row[attrIndex].asBool
            switch p {
            case .eq: return lhs == constant
            case .ne: return lhs != constant
            // false < true ordering for completeness.
            case .lt: return !lhs && constant
            case .le: return !lhs || (lhs == constant)
            case .gt: return lhs && !constant
            case .ge: return lhs || (lhs == constant)
            }
        }
        super.init(input: input)
    }

    public init(input: any Operator, predicate: PredicateAttributeAttribute) {
        let leftIndex = predicate.attrLeftIndex
        let rightIndex = predicate.attrRightIndex
        let p = predicate.predicateType
        self.select = { row in
            let lhs = row[leftIndex]
            let rhs = row[rightIndex]
            switch p {
            case .eq: return lhs == rhs
            case .ne: return lhs != rhs
            case .lt: return lhs < rhs
            case .le: return lhs <= rhs
            case .gt: return lhs > rhs
            case .ge: return lhs >= rhs
            }
        }
        super.init(input: input)
    }

    public func open() {
        input.open()
    }

    public func next() -> Bool {
        while input.next() {
            if select(input.getOutput()) { return true }
        }
        return false
    }

    public func close() {
        input.close()
    }

    public func getOutput() -> [Register] {
        input.getOutput()
    }
}

// MARK: - Sort

/// Sorts the input by the given criteria. Materialises all rows on the first
/// `next()` call, then streams them out one row per call.
///
/// Optional spillover: when `memoryBudgetBytes` is non-nil and the accumulated
/// row bytes exceed the budget during collection, the current in-memory batch
/// is sorted and written to a temporary file as one "run". After the input is
/// drained, runs are k-way-merged back through a min-heap. This bounds peak
/// memory at the cost of disk I/O.
public final class Sort: UnaryOperator, Operator {
    /// One element of `ORDER BY column1 [ASC|DESC] [, column2 [ASC|DESC] ...]`.
    public struct Criterion: Sendable {
        public let attrIndex: Int
        public let descending: Bool
        public init(attrIndex: Int, descending: Bool) {
            self.attrIndex = attrIndex
            self.descending = descending
        }
    }

    private let criteria: [Criterion]
    private let memoryBudgetBytes: Int?
    /// Per-attribute wire payload widths for the budgeted external-sort path
    /// (char → declared width, `int64`/`double` → 8, `bool` → 1). Required only
    /// when `memoryBudgetBytes` is set; the in-memory path orders `Register`s
    /// directly and ignores it.
    private let attributeWidths: [Int]?

    private var collected = false
    private var results: [[Register]] = []
    private var resultsIndex = 0

    private var spillover: SortSpillover?

    public init(
        input: any Operator,
        criteria: [Criterion],
        memoryBudgetBytes: Int? = nil,
        attributeWidths: [Int]? = nil
    ) {
        self.criteria = criteria
        self.memoryBudgetBytes = memoryBudgetBytes
        self.attributeWidths = attributeWidths
        super.init(input: input)
    }

    public func open() {
        input.open()
    }

    public func next() -> Bool {
        if collected {
            if let spill = spillover {
                return spill.next()
            }
            resultsIndex += 1
            return resultsIndex < results.count
        }
        collected = true

        // No budget (or no column widths) → sort entirely in memory. This is
        // the planner's default path; nothing touches disk.
        guard let budget = memoryBudgetBytes, let widths = attributeWidths else {
            let cmp = makeComparator(criteria: criteria)
            while input.next() {
                results.append(snapshot(input.getOutput()))
            }
            results.sort(by: cmp)
            return !results.isEmpty
        }

        // Budgeted → stream every row through the file-based external sort,
        // which keeps peak memory under `budget` bytes.
        let rawCmp = makeRowComparator(criteria: criteria, attributeWidths: widths)
        var spill: SortSpillover? = nil
        while input.next() {
            let row = input.getOutput()
            if spill == nil {
                spill = try? SortSpillover.create(
                    attributeWidths: widths,
                    memSize: budget,
                    compare: rawCmp
                )
            }
            try? spill?.write(row)
        }

        guard let spill else { return false }  // empty input
        try? spill.finish()
        spillover = spill
        return spill.next()
    }

    public func close() {
        input.close()
        results.removeAll()
        resultsIndex = 0
        spillover?.close()
        spillover = nil
        collected = false
    }

    public func getOutput() -> [Register] {
        if let spill = spillover { return spill.current }
        return results[resultsIndex]
    }
}

@inline(__always)
private func makeComparator(criteria: [Sort.Criterion]) -> ([Register], [Register]) -> Bool {
    return { lhs, rhs in
        for criterion in criteria {
            let l = lhs[criterion.attrIndex]
            let r = rhs[criterion.attrIndex]
            if l == r { continue }
            return criterion.descending ? l > r : l < r
        }
        return false
    }
}

// MARK: - HashJoin

/// Inner equi-join on one attribute; left input must have unique keys.
/// Builds a hash table on the entire left input on the first `next()`,
/// then probes the right input one tuple at a time.
public final class HashJoin: BinaryOperator, Operator {
    private let attrIndexLeft: Int
    private let attrIndexRight: Int
    private var leftValues: [Register: [Register]] = [:]
    private var output: [Register] = []

    public init(
        inputLeft: any Operator,
        inputRight: any Operator,
        attrIndexLeft: Int,
        attrIndexRight: Int
    ) {
        self.attrIndexLeft = attrIndexLeft
        self.attrIndexRight = attrIndexRight
        super.init(inputLeft: inputLeft, inputRight: inputRight)
    }

    public func open() {
        inputLeft.open()
        inputRight.open()
    }

    public func next() -> Bool {
        // Build phase: drain the left input on the first call. Subsequent
        // calls fall straight through (inputLeft.next() returns false).
        while inputLeft.next() {
            let row = inputLeft.getOutput()
            let key = row[attrIndexLeft].copy()
            leftValues[key] = snapshot(row)
        }

        while inputRight.next() {
            let row = inputRight.getOutput()
            let key = row[attrIndexRight]
            if let leftRow = leftValues[key] {
                output = leftRow + row
                return true
            }
        }
        return false
    }

    public func close() {
        inputLeft.close()
        inputRight.close()
        leftValues.removeAll()
        output.removeAll()
    }

    public func getOutput() -> [Register] { output }
}

// MARK: - HashAggregation

/// Groups by `groupByAttrs` and computes one or more aggregate functions.
public final class HashAggregation: UnaryOperator, Operator {
    public struct AggrFunc: Sendable {
        public enum Function: Sendable { case min, max, sum, count }
        public let function: Function
        public let attrIndex: Int
        public init(function: Function, attrIndex: Int) {
            self.function = function
            self.attrIndex = attrIndex
        }
    }

    private let groupByAttrs: [Int]
    private let aggrFuncs: [AggrFunc]
    private var output: [[Register]] = []
    private var outputIndex = 0

    public init(input: any Operator, groupByAttrs: [Int], aggrFuncs: [AggrFunc]) {
        self.groupByAttrs = groupByAttrs
        self.aggrFuncs = aggrFuncs
        super.init(input: input)
    }

    public func open() {
        input.open()
    }

    public func next() -> Bool {
        if !output.isEmpty {
            outputIndex += 1
            return outputIndex < output.count
        }

        var values: [[Register]: [Register]] = [:]

        while input.next() {
            let row = input.getOutput()
            let key = groupByAttrs.map { row[$0].copy() }

            if aggrFuncs.isEmpty { continue }

            let keyDidNotExist = (values[key] == nil)
            var group = values[key] ?? Array(repeating: Register(), count: aggrFuncs.count)

            for (i, fn) in aggrFuncs.enumerated() {
                let attr = row[fn.attrIndex]
                switch fn.function {
                case .sum:
                    group[i] =
                        keyDidNotExist
                        ? attr.copy()
                        : Register.from(int: group[i].asInt &+ attr.asInt)
                case .count:
                    group[i] =
                        keyDidNotExist
                        ? Register.from(int: 1)
                        : Register.from(int: group[i].asInt &+ 1)
                case .min:
                    if keyDidNotExist || group[i] > attr {
                        group[i] = attr.copy()
                    }
                case .max:
                    if keyDidNotExist || group[i] < attr {
                        group[i] = attr.copy()
                    }
                }
            }

            values[key] = group
        }

        for (key, group) in values {
            output.append(key + group)
        }

        return !output.isEmpty
    }

    public func close() {
        input.close()
        output.removeAll()
        outputIndex = 0
    }

    public func getOutput() -> [Register] {
        output[outputIndex]
    }
}

// MARK: - Union

/// Computes the union of the two inputs with set semantics.
public final class Union: BinaryOperator, Operator {
    private var leftIsFinished = false
    private var seen: Set<[Register]> = []

    public override init(inputLeft: any Operator, inputRight: any Operator) {
        super.init(inputLeft: inputLeft, inputRight: inputRight)
    }

    public func open() {
        inputLeft.open()
        inputRight.open()
    }

    public func next() -> Bool {
        while inputLeft.next() {
            let row = snapshot(inputLeft.getOutput())
            if seen.insert(row).inserted { return true }
        }
        leftIsFinished = true
        while inputRight.next() {
            let row = snapshot(inputRight.getOutput())
            if seen.insert(row).inserted { return true }
        }
        return false
    }

    public func close() {
        inputLeft.close()
        inputRight.close()
        leftIsFinished = false
        seen.removeAll()
    }

    public func getOutput() -> [Register] {
        leftIsFinished ? inputRight.getOutput() : inputLeft.getOutput()
    }
}

// MARK: - UnionAll

/// Computes the union of the two inputs with bag semantics (concatenation).
public final class UnionAll: BinaryOperator, Operator {
    private var leftIsFinished = false

    public override init(inputLeft: any Operator, inputRight: any Operator) {
        super.init(inputLeft: inputLeft, inputRight: inputRight)
    }

    public func open() {
        inputLeft.open()
        inputRight.open()
    }

    public func next() -> Bool {
        if inputLeft.next() { return true }
        leftIsFinished = true
        return inputRight.next()
    }

    public func close() {
        inputLeft.close()
        inputRight.close()
        leftIsFinished = false
    }

    public func getOutput() -> [Register] {
        leftIsFinished ? inputRight.getOutput() : inputLeft.getOutput()
    }
}

// MARK: - Intersect

/// Computes `inputLeft ∩ inputRight` with set semantics.
public final class Intersect: BinaryOperator, Operator {
    private var values: Set<[Register]> = []

    public override init(inputLeft: any Operator, inputRight: any Operator) {
        super.init(inputLeft: inputLeft, inputRight: inputRight)
    }

    public func open() {
        inputLeft.open()
        inputRight.open()
    }

    public func next() -> Bool {
        while inputRight.next() {
            values.insert(snapshot(inputRight.getOutput()))
        }
        while inputLeft.next() {
            let row = snapshot(inputLeft.getOutput())
            if values.remove(row) != nil { return true }
        }
        return false
    }

    public func close() {
        inputLeft.close()
        inputRight.close()
        values.removeAll()
    }

    public func getOutput() -> [Register] {
        inputLeft.getOutput()
    }
}

// MARK: - IntersectAll

/// Computes `inputLeft ∩ inputRight` with bag semantics.
public final class IntersectAll: BinaryOperator, Operator {
    private var values: [[Register]: UInt64] = [:]

    public override init(inputLeft: any Operator, inputRight: any Operator) {
        super.init(inputLeft: inputLeft, inputRight: inputRight)
    }

    public func open() {
        inputLeft.open()
        inputRight.open()
    }

    public func next() -> Bool {
        while inputRight.next() {
            let row = snapshot(inputRight.getOutput())
            values[row, default: 0] &+= 1
        }
        while inputLeft.next() {
            let row = snapshot(inputLeft.getOutput())
            if let count = values[row], count > 0 {
                values[row] = count - 1
                return true
            }
        }
        return false
    }

    public func close() {
        inputLeft.close()
        inputRight.close()
        values.removeAll()
    }

    public func getOutput() -> [Register] {
        inputLeft.getOutput()
    }
}

// MARK: - Except

/// Computes `inputLeft - inputRight` with set semantics.
public final class Except: BinaryOperator, Operator {
    private var values: Set<[Register]> = []

    public override init(inputLeft: any Operator, inputRight: any Operator) {
        super.init(inputLeft: inputLeft, inputRight: inputRight)
    }

    public func open() {
        inputLeft.open()
        inputRight.open()
    }

    public func next() -> Bool {
        while inputRight.next() {
            values.insert(snapshot(inputRight.getOutput()))
        }
        while inputLeft.next() {
            let row = snapshot(inputLeft.getOutput())
            if values.insert(row).inserted { return true }
        }
        return false
    }

    public func close() {
        inputLeft.close()
        inputRight.close()
        values.removeAll()
    }

    public func getOutput() -> [Register] {
        inputLeft.getOutput()
    }
}

// MARK: - ExceptAll

/// Computes `inputLeft - inputRight` with bag semantics.
public final class ExceptAll: BinaryOperator, Operator {
    private var values: [[Register]: UInt64] = [:]

    public override init(inputLeft: any Operator, inputRight: any Operator) {
        super.init(inputLeft: inputLeft, inputRight: inputRight)
    }

    public func open() {
        inputLeft.open()
        inputRight.open()
    }

    public func next() -> Bool {
        while inputRight.next() {
            let row = snapshot(inputRight.getOutput())
            values[row, default: 0] &+= 1
        }
        while inputLeft.next() {
            let row = snapshot(inputLeft.getOutput())
            if let count = values[row], count > 0 {
                values[row] = count - 1
            } else {
                return true
            }
        }
        return false
    }

    public func close() {
        inputLeft.close()
        inputRight.close()
        values.removeAll()
    }

    public func getOutput() -> [Register] {
        inputLeft.getOutput()
    }
}
