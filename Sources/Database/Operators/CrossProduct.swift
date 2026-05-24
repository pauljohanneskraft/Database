/// Cartesian product of two inputs. On the first `next()` call the left
/// input is fully materialised into an array of register snapshots; from
/// then on, every right tuple is paired with each materialised left tuple
/// in turn.
///
/// Output register identities are stable across `next()` calls: the first
/// `leftWidth` slots reference the left snapshot for the current row, and
/// the remaining slots are owned by us and rewritten in place from the
/// right input's current tuple.
public final class CrossProduct: BinaryOperator, Operator {
    private var leftBuffered: [[Register]] = []
    private var leftIndex: Int = 0
    private var rightExhausted: Bool = false
    private var hasRightRow: Bool = false
    private var output: [Register] = []
    private var leftWidth: Int = 0
    private var rightOutputs: [Register] = []

    public override init(inputLeft: any Operator, inputRight: any Operator) {
        super.init(inputLeft: inputLeft, inputRight: inputRight)
    }

    public func open() {
        inputLeft.open()
        inputRight.open()
    }

    public func next() -> Bool {
        if leftBuffered.isEmpty {
            // Drain the left input once.
            while inputLeft.next() {
                leftBuffered.append(snapshot(inputLeft.getOutput()))
            }
            if leftBuffered.isEmpty { return false }
            leftWidth = leftBuffered[0].count

            // Cache the right output's register identities so we can reuse
            // them in the composed output.
            rightOutputs = inputRight.getOutput()
            // Prime the right side.
            if !inputRight.next() { return false }
            hasRightRow = true
            leftIndex = 0
            buildOutput()
            return true
        }

        if !hasRightRow { return false }

        leftIndex += 1
        if leftIndex < leftBuffered.count {
            buildOutput()
            return true
        }

        // Advance the right side; rewind left.
        if !inputRight.next() {
            hasRightRow = false
            return false
        }
        leftIndex = 0
        buildOutput()
        return true
    }

    public func close() {
        inputLeft.close()
        inputRight.close()
        leftBuffered.removeAll()
        output.removeAll()
        rightOutputs.removeAll()
        leftIndex = 0
        hasRightRow = false
    }

    public func getOutput() -> [Register] { output }

    private func buildOutput() {
        // Compose `output` = leftBuffered[leftIndex] ++ rightOutputs. The
        // right-side registers are mutated in place by inputRight.next() —
        // we hold onto their references, so the composed array stays in
        // sync without per-row copying.
        let left = leftBuffered[leftIndex]
        if output.count != left.count + rightOutputs.count {
            output = left + rightOutputs
        } else {
            for i in 0..<left.count { output[i] = left[i] }
            for j in 0..<rightOutputs.count { output[left.count + j] = rightOutputs[j] }
        }
    }
}
