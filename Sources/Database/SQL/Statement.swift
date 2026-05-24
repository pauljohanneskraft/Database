/// Top-level SQL statement. The parser produces one `Statement` per call;
/// the executor dispatches: `select` runs through the planner, the others
/// mutate the database directly.
public enum Statement: Sendable {
    case select(SelectExpr)
    case createTable(CreateTableAST)
    case createIndex(CreateIndexAST)
    case dropTable(name: String, span: Span)
    case insertInto(InsertAST)
    case copyFrom(CopyAST)
}

/// `CREATE INDEX name ON table (column);`
public struct CreateIndexAST: Sendable {
    public let name: String
    public let nameSpan: Span
    public let table: String
    public let column: String
}

/// `CREATE TABLE name (col1 type1, col2 type2, …, PRIMARY KEY (cols…));`
public struct CreateTableAST: Sendable {
    public struct Column: Sendable, Equatable {
        public let name: String
        public let type: SchemaType
    }
    public let name: String
    public let nameSpan: Span
    public let columns: [Column]
    public let primaryKey: [String]
}

/// `INSERT INTO name VALUES (v1, v2, …);`
public struct InsertAST: Sendable {
    public let table: String
    public let tableSpan: Span
    public let values: [QueryAST.Literal]
}

/// `COPY name FROM 'path' CSV [HEADER];`
public struct CopyAST: Sendable {
    public let table: String
    public let tableSpan: Span
    public let path: String
    public let hasHeader: Bool
}
