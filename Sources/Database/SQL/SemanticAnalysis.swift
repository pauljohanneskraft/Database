/// Output of `SemanticAnalysis.analyse`: relations and references resolved
/// against the database schema, with column indices ready for the planner.
public struct BoundQuery {
    public struct BoundRel {
        public let alias: String
        public let table: SchemaTable
        /// Position of this relation in the planner's left-to-right fold,
        /// i.e. the order in which `TableScan`s are introduced.
        public let scanIndex: Int
    }

    public struct BoundAttr {
        public let scanIndex: Int  // which relation this attribute came from
        public let columnIndex: Int  // column ordinal within that relation
        public let type: SchemaType
        public let name: String  // for display / diagnostics
    }

    /// One item of the bound SELECT list: a plain column or a bound
    /// aggregate call. A nil `arg` only ever occurs with `.count` (`COUNT(*)`).
    public enum BoundSelectItem {
        case column(BoundAttr)
        case aggregate(function: QueryAST.AggregateFunction, arg: BoundAttr?)
    }

    /// One bound `ORDER BY` term.
    public struct BoundOrderItem {
        public enum Key {
            case attr(BoundAttr)
            /// 0-based index into `projections` (or, when `projections` is
            /// empty — `SELECT *` — into the full flattened relation column
            /// order), resolved from a 1-based `ORDER BY <n>` position.
            case projectionIndex(Int)
        }
        public let key: Key
        public let descending: Bool
    }

    public let relations: [BoundRel]
    /// Empty means SELECT *.
    public let projections: [BoundSelectItem]
    public let selections: [(BoundAttr, QueryAST.ComparisonOp, QueryAST.Literal)]
    /// Equality attr-attr predicates only — hash-joinable. See `attrComparisons`.
    public let joins: [(BoundAttr, BoundAttr)]
    /// Non-equality attr-attr predicates; always realised as a post-join filter.
    public let attrComparisons: [(BoundAttr, QueryAST.ComparisonOp, BoundAttr)]
    /// `GROUP BY` columns (empty = no explicit grouping).
    public let groupBy: [BoundAttr]
    /// `ORDER BY` terms (empty = unordered).
    public let orderBy: [BoundOrderItem]
    /// Whether the query groups explicitly or projects any aggregate call.
    public let hasAggregation: Bool
}

/// A bound `SelectExpr`: each leaf is a `BoundQuery`, interior nodes are set
/// operations whose operands have already been checked for union-compatibility.
public indirect enum BoundSelectExpr {
    case leaf(BoundQuery)
    case setOp(left: BoundSelectExpr, op: SetOpKind, all: Bool, right: BoundSelectExpr)
}

/// Resolves attribute references and validates that the query is type-
/// compatible with the schema. Does not build operators (that's the
/// planner's job).
public struct SemanticAnalysis {
    public init() {}

    /// Binds a (possibly set-operation) SELECT expression. Set-operation
    /// operands must be union-compatible: same output arity and per-column
    /// type.
    public func analyse(_ expr: SelectExpr, schema: Schema) throws -> BoundSelectExpr {
        switch expr {
        case .leaf(let query):
            return .leaf(try analyse(query, schema: schema))
        case .setOp(let left, let op, let all, let right):
            let boundLeft = try analyse(left, schema: schema)
            let boundRight = try analyse(right, schema: schema)
            let lTypes = Self.outputTypes(boundLeft)
            let rTypes = Self.outputTypes(boundRight)
            guard lTypes.count == rTypes.count else {
                throw SQLError.bind(
                    "set operation operands have different column counts (\(lTypes.count) vs \(rTypes.count))"
                )
            }
            for (i, (l, r)) in zip(lTypes, rTypes).enumerated() where !Self.columnsCompatible(l, r) {
                throw SQLError.bind(
                    "set operation column \(i + 1) has incompatible types (\(l.name) vs \(r.name))"
                )
            }
            return .setOp(left: boundLeft, op: op, all: all, right: boundRight)
        }
    }

    /// Output column types of a bound select expression. For a leaf, that's the
    /// projection types, or — for `SELECT *` — every column of every relation
    /// in scan order. For a set operation, the left operand's types (operands
    /// are already proven compatible).
    private static func outputTypes(_ expr: BoundSelectExpr) -> [SchemaType] {
        switch expr {
        case .leaf(let q):
            if q.projections.isEmpty {
                return q.relations.flatMap { $0.table.columns.map(\.type) }
            }
            return q.projections.map { item in
                switch item {
                case .column(let attr): return attr.type
                case .aggregate(let function, let arg):
                    switch function {
                    case .count: return .integer
                    case .sum, .min, .max:
                        // `analyse` requires a non-nil arg for every function
                        // but `.count`, so this is always bound by then.
                        return arg!.type
                    }
                }
            }
        case .setOp(let left, _, _, _):
            return outputTypes(left)
        }
    }

    public func analyse(_ ast: QueryAST, schema: Schema) throws -> BoundQuery {
        // Resolve each relation to a SchemaTable.
        var boundRels: [BoundQuery.BoundRel] = []
        var aliasSeen: Set<String> = []
        for (idx, rel) in ast.relations.enumerated() {
            guard let table = schema.tables.first(where: { $0.id == rel.table }) else {
                throw SQLError.bind("unknown relation `\(rel.table)`")
            }
            let alias = rel.alias ?? rel.table
            if !aliasSeen.insert(alias).inserted {
                throw SQLError.bind("duplicate relation alias `\(alias)`")
            }
            boundRels.append(BoundQuery.BoundRel(alias: alias, table: table, scanIndex: idx))
        }

        let resolveAttr: (QueryAST.AttrRef) throws -> BoundQuery.BoundAttr = { ref in
            try Self.resolveAttribute(ref, in: boundRels)
        }

        let groupBy = try ast.groupBy.map(resolveAttr)

        let projections = try ast.projections.map { item -> BoundQuery.BoundSelectItem in
            switch item {
            case .column(let ref):
                return .column(try resolveAttr(ref))
            case .aggregate(let function, let arg):
                if function == .count {
                    // `COUNT(*)` (nil arg) or `COUNT(col)`.
                    return .aggregate(function: function, arg: try arg.map(resolveAttr))
                }
                guard let arg else {
                    throw SQLError.bind("`*` is only valid inside COUNT(...)")
                }
                let boundArg = try resolveAttr(arg)
                if function == .sum, boundArg.type.tclass != .integer, boundArg.type.tclass != .double {
                    throw SQLError.bind(
                        "SUM requires a numeric column, got `\(boundArg.name)` (\(boundArg.type.name))"
                    )
                }
                return .aggregate(function: function, arg: boundArg)
            }
        }

        // A query "has aggregation" if it groups explicitly or projects any
        // aggregate call; every plain-column projection then must be a GROUP
        // BY key (standard SQL rule), and `SELECT *` can't be combined with
        // either (there's no way to express "one row per group" over *).
        let hasAggregation =
            !groupBy.isEmpty
            || projections.contains {
                if case .aggregate = $0 { return true }
                return false
            }
        if hasAggregation {
            guard !projections.isEmpty else {
                throw SQLError.bind(
                    "SELECT * cannot be combined with GROUP BY or aggregate functions; list explicit columns"
                )
            }
            for item in projections {
                guard case .column(let attr) = item else { continue }
                guard Self.attr(attr, isIn: groupBy) else {
                    throw SQLError.bind(
                        "column `\(attr.name)` must appear in GROUP BY or be used in an aggregate function"
                    )
                }
            }
        }

        let selections = try ast.selections.map {
            (ref, op, lit) -> (BoundQuery.BoundAttr, QueryAST.ComparisonOp, QueryAST.Literal) in
            let attr = try resolveAttr(ref)
            try Self.checkLiteralType(lit, name: attr.name, type: attr.type)
            return (attr, op, lit)
        }
        let joins = try ast.joins.map { (l, r) -> (BoundQuery.BoundAttr, BoundQuery.BoundAttr) in
            let lA = try resolveAttr(l)
            let rA = try resolveAttr(r)
            if !Self.columnsCompatible(lA.type, rA.type) {
                throw SQLError.bind(
                    "join attributes `\(lA.name)` and `\(rA.name)` have incompatible types"
                )
            }
            return (lA, rA)
        }
        let attrComparisons = try ast.attrComparisons.map {
            (l, op, r) -> (BoundQuery.BoundAttr, QueryAST.ComparisonOp, BoundQuery.BoundAttr) in
            let lA = try resolveAttr(l)
            let rA = try resolveAttr(r)
            if !Self.columnsCompatible(lA.type, rA.type) {
                throw SQLError.bind(
                    "compared attributes `\(lA.name)` and `\(rA.name)` have incompatible types"
                )
            }
            return (lA, op, rA)
        }

        let orderBy = try ast.orderBy.map { item -> BoundQuery.BoundOrderItem in
            switch item.key {
            case .name(let ref):
                let attr = try resolveAttr(ref)
                if hasAggregation {
                    guard Self.attr(attr, isIn: groupBy) else {
                        throw SQLError.bind(
                            "ORDER BY column `\(attr.name)` must appear in GROUP BY or be used in an aggregate function"
                        )
                    }
                }
                return BoundQuery.BoundOrderItem(key: .attr(attr), descending: item.descending)
            case .position(let n):
                let count =
                    projections.isEmpty
                    ? boundRels.reduce(0) { $0 + $1.table.columns.count }
                    : projections.count
                guard n >= 1, n <= count else {
                    throw SQLError.bind(
                        "ORDER BY position \(n) is out of range (SELECT list has \(count) column(s))"
                    )
                }
                return BoundQuery.BoundOrderItem(key: .projectionIndex(n - 1), descending: item.descending)
            }
        }

        return BoundQuery(
            relations: boundRels,
            projections: projections,
            selections: selections,
            joins: joins,
            attrComparisons: attrComparisons,
            groupBy: groupBy,
            orderBy: orderBy,
            hasAggregation: hasAggregation
        )
    }

    // MARK: - Helpers

    private static func attr(_ attr: BoundQuery.BoundAttr, isIn list: [BoundQuery.BoundAttr]) -> Bool {
        list.contains { $0.scanIndex == attr.scanIndex && $0.columnIndex == attr.columnIndex }
    }

    private static func resolveAttribute(
        _ ref: QueryAST.AttrRef,
        in rels: [BoundQuery.BoundRel]
    ) throws -> BoundQuery.BoundAttr {
        if let relName = ref.relation {
            // Qualified — find the relation, then the column.
            guard let rel = rels.first(where: { $0.alias == relName }) else {
                throw SQLError.bind("unknown relation `\(relName)`")
            }
            guard let colIdx = rel.table.columns.firstIndex(where: { $0.id == ref.name }) else {
                throw SQLError.bind("relation `\(relName)` has no attribute `\(ref.name)`")
            }
            return BoundQuery.BoundAttr(
                scanIndex: rel.scanIndex,
                columnIndex: colIdx,
                type: rel.table.columns[colIdx].type,
                name: "\(relName).\(ref.name)"
            )
        }
        // Unqualified — exactly one relation must own a column with this name.
        var matches: [(Int, Int, SchemaType)] = []
        for rel in rels {
            if let colIdx = rel.table.columns.firstIndex(where: { $0.id == ref.name }) {
                matches.append((rel.scanIndex, colIdx, rel.table.columns[colIdx].type))
            }
        }
        switch matches.count {
        case 0:
            throw SQLError.bind("unknown attribute `\(ref.name)`")
        case 1:
            let (scanIdx, colIdx, type) = matches[0]
            return BoundQuery.BoundAttr(
                scanIndex: scanIdx,
                columnIndex: colIdx,
                type: type,
                name: ref.name
            )
        default:
            throw SQLError.bind("ambiguous attribute `\(ref.name)` (matches multiple relations)")
        }
    }

    /// Checks that `lit` is a valid value for a column/attribute named `name`
    /// with schema type `type`, throwing a `SQLError.bind` with a consistent
    /// message otherwise. Shared by `SELECT` predicate binding here and by
    /// `SQLExecutor.runInsert`'s INSERT-value binding.
    static func checkLiteralType(
        _ lit: QueryAST.Literal,
        name: String,
        type: SchemaType
    ) throws {
        let compatible: Bool
        switch (lit, type.tclass) {
        case (.int, .integer), (.string, .char), (.double, .double), (.bool, .bool):
            compatible = true
        default:
            compatible = false
        }
        guard compatible else {
            let literalTypeName = Self.literalTypeName(lit)
            throw SQLError.bind(
                "attribute `\(name)` is \(type.name) but literal is "
                    + "\(Self.article(for: literalTypeName)) \(literalTypeName)"
            )
        }
    }

    /// The SQL-facing type name of a literal, for diagnostics. Delegates to
    /// `SchemaType.name` so the two vocabularies can't drift, except for
    /// `.string` literals: they bind against `.char` columns, but users write
    /// `'...'` literals, not `char`s, so the diagnostic says "string".
    private static func literalTypeName(_ lit: QueryAST.Literal) -> String {
        switch lit {
        case .string: return "string"
        case .int: return SchemaType.integer.name
        case .double: return SchemaType.double.name
        case .bool: return SchemaType.bool.name
        }
    }

    /// "a" or "an" for each of the four literal type names diagnostics use.
    private static let articles: [String: String] = [
        "integer": "an", "double": "a", "string": "a", "bool": "a",
    ]

    private static func article(for word: String) -> String {
        articles[word] ?? "a"
    }

    private static func columnsCompatible(_ a: SchemaType, _ b: SchemaType) -> Bool {
        if a.tclass != b.tclass { return false }
        if a.tclass == .char && a.length != b.length { return false }
        return true
    }
}
