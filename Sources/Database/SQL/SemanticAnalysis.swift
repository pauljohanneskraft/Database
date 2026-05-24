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
        public let scanIndex: Int   // which relation this attribute came from
        public let columnIndex: Int // column ordinal within that relation
        public let type: SchemaType
        public let name: String     // for display / diagnostics
    }

    public let relations: [BoundRel]
    /// Empty means SELECT *.
    public let projections: [BoundAttr]
    public let selections: [(BoundAttr, QueryAST.Literal)]
    public let joins: [(BoundAttr, BoundAttr)]
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
            return q.projections.map(\.type)
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

        let projections = try ast.projections.map(resolveAttr)
        let selections = try ast.selections.map { (ref, lit) -> (BoundQuery.BoundAttr, QueryAST.Literal) in
            let attr = try resolveAttr(ref)
            try Self.checkLiteralType(lit, attr: attr)
            return (attr, lit)
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

        return BoundQuery(
            relations: boundRels,
            projections: projections,
            selections: selections,
            joins: joins
        )
    }

    // MARK: - Helpers

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

    private static func checkLiteralType(
        _ lit: QueryAST.Literal,
        attr: BoundQuery.BoundAttr
    ) throws {
        switch (lit, attr.type.tclass) {
        case (.int, .integer): return
        case (.string, .char): return
        case (.double, .integer):
            throw SQLError.bind("attribute `\(attr.name)` is integer but literal is a double")
        case (.string, .integer):
            throw SQLError.bind("attribute `\(attr.name)` is integer but literal is a string")
        case (.int, .char):
            throw SQLError.bind("attribute `\(attr.name)` is char but literal is an integer")
        case (.double, .char):
            throw SQLError.bind("attribute `\(attr.name)` is char but literal is a double")
        case (.bool, _):
            throw SQLError.bind("bool literals are not yet bindable to schema columns")
        }
    }

    private static func columnsCompatible(_ a: SchemaType, _ b: SchemaType) -> Bool {
        if a.tclass != b.tclass { return false }
        if a.tclass == .char && a.length != b.length { return false }
        return true
    }
}
