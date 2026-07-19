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

    /// Comparison operator carried by a WHERE predicate. Kept independent of
    /// `Operators.Select.PredicateType` — `SemanticAnalysis`/`QueryAST` don't
    /// build operators, that's the planner's job.
    public enum ComparisonOp: Equatable, Sendable {
        case eq, ne, lt, le, gt, ge
    }

    /// Aggregate functions exposed by `GROUP BY`. `count` also serves
    /// `COUNT(*)` (see `SelectItem.aggregate` with a nil argument).
    public enum AggregateFunction: Equatable, Sendable {
        case count, sum, min, max
    }

    /// One item of the SELECT list: a plain column or an aggregate call. A nil
    /// aggregate argument denotes `COUNT(*)`.
    public enum SelectItem: Equatable, Sendable {
        case column(AttrRef)
        case aggregate(function: AggregateFunction, arg: AttrRef?)
    }

    /// One `ORDER BY` term. The sort key references an output column either by
    /// 1-based position or by name; `descending` is `DESC`.
    public struct OrderItem: Equatable, Sendable {
        public enum Key: Equatable, Sendable {
            case position(Int)
            case name(AttrRef)
        }
        public let key: Key
        public let descending: Bool
        public init(key: Key, descending: Bool) {
            self.key = key
            self.descending = descending
        }
    }

    public let relations: [Relation]
    /// Empty `projections` means `SELECT *` (pass-through identity).
    public let projections: [SelectItem]
    public let selections: [(AttrRef, ComparisonOp, Literal)]
    /// Equality attr-attr predicates only — these are what the planner treats
    /// as hash-joinable. Non-equality attr-attr predicates go in
    /// `attrComparisons` instead.
    public let joins: [(AttrRef, AttrRef)]
    /// Non-equality attr-attr predicates (`a.x < b.y`, etc.); always realised
    /// as a post-join `Select` filter, never as a `HashJoin` condition.
    public let attrComparisons: [(AttrRef, ComparisonOp, AttrRef)]
    /// `GROUP BY` columns (empty = no explicit grouping).
    public let groupBy: [AttrRef]
    /// `ORDER BY` terms (empty = unordered).
    public let orderBy: [OrderItem]

    public init(
        relations: [Relation],
        projections: [SelectItem],
        selections: [(AttrRef, ComparisonOp, Literal)],
        joins: [(AttrRef, AttrRef)],
        attrComparisons: [(AttrRef, ComparisonOp, AttrRef)] = [],
        groupBy: [AttrRef] = [],
        orderBy: [OrderItem] = []
    ) {
        self.relations = relations
        self.projections = projections
        self.selections = selections
        self.joins = joins
        self.attrComparisons = attrComparisons
        self.groupBy = groupBy
        self.orderBy = orderBy
    }

    public static func == (lhs: QueryAST, rhs: QueryAST) -> Bool {
        guard lhs.relations == rhs.relations,
            lhs.projections == rhs.projections,
            lhs.groupBy == rhs.groupBy,
            lhs.orderBy == rhs.orderBy,
            lhs.selections.count == rhs.selections.count,
            lhs.joins.count == rhs.joins.count,
            lhs.attrComparisons.count == rhs.attrComparisons.count
        else { return false }
        for (a, b) in zip(lhs.selections, rhs.selections) where a.0 != b.0 || a.1 != b.1 || a.2 != b.2 {
            return false
        }
        for (a, b) in zip(lhs.joins, rhs.joins) where a.0 != b.0 || a.1 != b.1 { return false }
        for (a, b) in zip(lhs.attrComparisons, rhs.attrComparisons) where a.0 != b.0 || a.1 != b.1 || a.2 != b.2 {
            return false
        }
        return true
    }
}
