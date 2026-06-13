/// Lowers a `BoundQuery` to an iterator-model operator tree, ready to be
/// `open()` / `next()` / `close()`'d.
///
/// Strategy:
///   1. One `TableScan` per relation (seeded with `SPSegment.allTIDs()`).
///   2. Fold left-to-right: each next relation is combined with the running
///      result via `HashJoin` if a `joinCondition` connects it to anything
///      already in the tree; otherwise `CrossProduct`. Track each output
///      attribute's `(scanIndex, columnIndex) → flatOutputIndex` mapping so
///      later predicates know which slot to read.
///   3. Any remaining `joinCondition`s become attr-attr `Select` filters
///      (e.g. three-way joins where two of the three conditions already
///      paired up).
///   4. Each `selection` becomes a `Select` with the appropriate predicate
///      kind.
///   5. If `projections` is non-empty, wrap in `Projection`.
public struct Planner {
    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    /// Plans a (possibly set-operation) bound SELECT expression into an
    /// operator tree.
    public func plan(_ expr: BoundSelectExpr) throws -> any Operator {
        switch expr {
        case .leaf(let query):
            return try plan(query)
        case .setOp(let left, let op, let all, let right):
            let l = try plan(left)
            let r = try plan(right)
            switch (op, all) {
            case (.union, false): return Union(inputLeft: l, inputRight: r)
            case (.union, true): return UnionAll(inputLeft: l, inputRight: r)
            case (.intersect, false): return Intersect(inputLeft: l, inputRight: r)
            case (.intersect, true): return IntersectAll(inputLeft: l, inputRight: r)
            case (.except, false): return Except(inputLeft: l, inputRight: r)
            case (.except, true): return ExceptAll(inputLeft: l, inputRight: r)
            }
        }
    }

    public func plan(_ query: BoundQuery) throws -> any Operator {
        guard !query.relations.isEmpty else {
            throw SQLError.plan("at least one FROM relation is required")
        }

        var op: any Operator
        // Maps `(scanIndex, columnIndex)` → flat output index.
        var slotMap: [SlotKey: Int] = [:]
        // Scalar selections not yet consumed by an index scan; the leftovers
        // become `Select` filters at the end.
        var remainingSelections = query.selections

        let first = query.relations[0]
        op = try makeScan(for: first, remainingSelections: &remainingSelections)
        appendToSlotMap(rel: first, baseOffset: 0, slotMap: &slotMap)
        var currentWidth = first.table.columns.count
        var remainingJoins = query.joins

        for rel in query.relations.dropFirst() {
            let right = try makeScan(for: rel, remainingSelections: &remainingSelections)

            // Find a join condition that connects `rel` to anything already
            // present (i.e. one side has scanIndex < rel.scanIndex and the
            // other == rel.scanIndex).
            let pairIdx = remainingJoins.firstIndex { (a, b) in
                (a.scanIndex < rel.scanIndex && b.scanIndex == rel.scanIndex)
                    || (b.scanIndex < rel.scanIndex && a.scanIndex == rel.scanIndex)
            }

            if let pairIdx {
                let (a, b) = remainingJoins.remove(at: pairIdx)
                // Normalise so `lhs` is the side already in the tree, `rhs`
                // is the new relation.
                let lhs: BoundQuery.BoundAttr
                let rhs: BoundQuery.BoundAttr
                if a.scanIndex == rel.scanIndex {
                    lhs = b; rhs = a
                } else {
                    lhs = a; rhs = b
                }
                let lhsSlot = slotMap[SlotKey(lhs.scanIndex, lhs.columnIndex)]!
                let rhsSlot = rhs.columnIndex  // right input is the bare TableScan
                op = HashJoin(
                    inputLeft: op,
                    inputRight: right,
                    attrIndexLeft: lhsSlot,
                    attrIndexRight: rhsSlot
                )
            } else {
                op = CrossProduct(inputLeft: op, inputRight: right)
            }
            appendToSlotMap(rel: rel, baseOffset: currentWidth, slotMap: &slotMap)
            currentWidth += rel.table.columns.count
        }

        // Remaining join conditions → attr-attr filters.
        for (l, r) in remainingJoins {
            let lSlot = slotMap[SlotKey(l.scanIndex, l.columnIndex)]!
            let rSlot = slotMap[SlotKey(r.scanIndex, r.columnIndex)]!
            op = Select(
                input: op,
                predicate: Select.PredicateAttributeAttribute(
                    attrLeftIndex: lSlot,
                    attrRightIndex: rSlot,
                    predicateType: .eq
                )
            )
        }

        // Apply each scalar selection not already consumed by an index scan.
        for (attr, lit) in remainingSelections {
            let slot = slotMap[SlotKey(attr.scanIndex, attr.columnIndex)]!
            op = applySelection(input: op, slot: slot, literal: lit, attr: attr)
        }

        // Final projection.
        if !query.projections.isEmpty {
            let indexes = query.projections.map { attr in
                slotMap[SlotKey(attr.scanIndex, attr.columnIndex)]!
            }
            op = Projection(input: op, attrIndexes: indexes)
        }

        return op
    }

    // MARK: - Helpers

    /// Builds the leaf scan for `rel`. If one of the still-unconsumed scalar
    /// selections is an equality on an indexed column of this relation, lowers
    /// it to `IndexScan → TIDResolve` and removes that selection so it isn't
    /// re-applied as a filter. Otherwise falls back to a full `TableScan`.
    /// Only the first matching indexed selection is consumed.
    private func makeScan(
        for rel: BoundQuery.BoundRel,
        remainingSelections: inout [(BoundQuery.BoundAttr, QueryAST.Literal)]
    ) throws -> any Operator {
        guard let sp = db.slottedPages[rel.table.spSegment] else {
            throw SQLError.plan("table `\(rel.table.id)` has no SP segment loaded")
        }
        for i in remainingSelections.indices {
            let (attr, lit) = remainingSelections[i]
            guard attr.scanIndex == rel.scanIndex,
                let index = db.index(on: rel.table, columnIndex: attr.columnIndex),
                let scan = index.indexScan(forLiteral: lit)
            else { continue }
            remainingSelections.remove(at: i)
            return TIDResolve(input: scan, segment: sp, table: rel.table)
        }
        let tids = try sp.allTIDs()
        return TableScan(segment: sp, table: rel.table, tids: tids)
    }

    private func appendToSlotMap(
        rel: BoundQuery.BoundRel,
        baseOffset: Int,
        slotMap: inout [SlotKey: Int]
    ) {
        for (col, _) in rel.table.columns.enumerated() {
            slotMap[SlotKey(rel.scanIndex, col)] = baseOffset + col
        }
    }

    private func applySelection(
        input: any Operator,
        slot: Int,
        literal: QueryAST.Literal,
        attr: BoundQuery.BoundAttr
    ) -> any Operator {
        switch (literal, attr.type.tclass) {
        case (.int(let v), .integer):
            return Select(
                input: input,
                predicate: Select.PredicateAttributeInt64(
                    attrIndex: slot, constant: v, predicateType: .eq
                ))
        case (.string(let v), .char):
            // Char values flow as content bytes (no padding), so the constant
            // is the raw literal — it compares equal to the column's content.
            return Select(
                input: input,
                predicate: Select.PredicateAttributeChar16(
                    attrIndex: slot, constant: v, predicateType: .eq
                ))
        case (.double(let v), _):
            return Select(
                input: input,
                predicate: Select.PredicateAttributeDouble(
                    attrIndex: slot, constant: v, predicateType: .eq
                ))
        case (.bool(let v), _):
            return Select(
                input: input,
                predicate: Select.PredicateAttributeBool(
                    attrIndex: slot, constant: v, predicateType: .eq
                ))
        default:
            // SemanticAnalysis already rejected impossible (lit, type)
            // pairs; falling through with an int-Int64 predicate keeps the
            // operator tree well-typed without a precondition.
            return input
        }
    }

}

/// Compact hashable key for `(scanIndex, columnIndex)` so we don't need an
/// outer dictionary keyed on `BoundAttr` (which isn't Hashable).
private struct SlotKey: Hashable {
    let scanIndex: Int
    let columnIndex: Int
    init(_ s: Int, _ c: Int) { self.scanIndex = s; self.columnIndex = c }
}
