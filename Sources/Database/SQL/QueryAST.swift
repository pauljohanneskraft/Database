/// The three SQL set operators. Each may carry an `ALL` modifier (bag vs. set
/// semantics) at the `SelectExpr` level.
public enum SetOpKind: Sendable, Equatable {
    case union
    case intersect
    case except
}

/// A SELECT statement, possibly a tree of set operations over single SELECTs.
/// Per the SQL standard, `INTERSECT` binds tighter than `UNION` / `EXCEPT`;
/// the parser encodes that precedence in the tree shape.
public indirect enum SelectExpr: Sendable {
    case leaf(QueryAST)
    case setOp(left: SelectExpr, op: SetOpKind, all: Bool, right: SelectExpr)
}

/// Flat AST produced by the parser. Matches the shape used by tinydb_parser:
/// relations + projections + WHERE-clause selections (attr = const) and
/// joins (attr = attr).
public struct QueryAST: Equatable, Sendable {
    public struct Relation: Equatable, Sendable {
        public let table: String
        public let alias: String?
        public let span: Span
        public init(table: String, alias: String?, span: Span) {
            self.table = table
            self.alias = alias
            self.span = span
        }
        /// Name used in WHERE / SELECT to refer to this relation.
        public var binding: String { alias ?? table }
    }

    public struct AttrRef: Equatable, Sendable {
        public let relation: String?
        public let name: String
        public let span: Span
        public init(relation: String?, name: String, span: Span) {
            self.relation = relation
            self.name = name
            self.span = span
        }
    }

    public enum Literal: Equatable, Sendable {
        case int(Int64)
        case double(Double)
        case string(String)
        case bool(Bool)
    }

    public let relations: [Relation]
    /// Empty `projections` means `SELECT *` (pass-through identity).
    public let projections: [AttrRef]
    public let selections: [(AttrRef, Literal)]
    public let joins: [(AttrRef, AttrRef)]

    public init(
        relations: [Relation],
        projections: [AttrRef],
        selections: [(AttrRef, Literal)],
        joins: [(AttrRef, AttrRef)]
    ) {
        self.relations = relations
        self.projections = projections
        self.selections = selections
        self.joins = joins
    }

    public static func == (lhs: QueryAST, rhs: QueryAST) -> Bool {
        guard lhs.relations == rhs.relations,
              lhs.projections == rhs.projections,
              lhs.selections.count == rhs.selections.count,
              lhs.joins.count == rhs.joins.count
        else { return false }
        for (a, b) in zip(lhs.selections, rhs.selections) where a.0 != b.0 || a.1 != b.1 { return false }
        for (a, b) in zip(lhs.joins, rhs.joins) where a.0 != b.0 || a.1 != b.1 { return false }
        return true
    }
}
