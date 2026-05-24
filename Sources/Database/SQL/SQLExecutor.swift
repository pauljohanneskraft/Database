import Foundation

/// Drives a single SQL statement against a `Database`. Owns the lex → parse →
/// (plan / mutate) pipeline so that the REPL and the test suite share the
/// exact same path.
///
/// For `SELECT`, returns the printed tuples (one per line). For DDL/DML,
/// returns a short status string (e.g. `"CREATE TABLE"`, `"INSERT 1"`,
/// `"COPY 8"`).
public struct SQLExecutor {
    public let db: Database

    public init(db: Database) {
        self.db = db
    }

    @discardableResult
    public func execute(_ source: String) throws -> String {
        var lexer = Lexer(source)
        let tokens = try lexer.tokenize()
        var parser = Parser(tokens)
        let stmt = try parser.parse()
        switch stmt {
        case .select(let expr):
            return try runSelect(expr)
        case .createTable(let ast):
            return try runCreateTable(ast)
        case .createIndex(let ast):
            return try runCreateIndex(ast)
        case .dropTable(let name, _):
            return try runDropTable(name: name)
        case .insertInto(let ast):
            return try runInsert(ast)
        case .copyFrom(let ast):
            return try runCopy(ast)
        }
    }

    // MARK: - SELECT

    private func runSelect(_ expr: SelectExpr) throws -> String {
        guard let schema = db.schema else {
            throw SQLError.bind("database has no schema")
        }
        let bound = try SemanticAnalysis().analyse(expr, schema: schema)
        let root = try Planner(db: db).plan(bound)
        let stream = TextOutput()
        let printer = Print(input: root, stream: stream)
        printer.open()
        while printer.next() {}
        printer.close()
        return stream.contents
    }

    // MARK: - DDL / DML

    private func runCreateTable(_ ast: CreateTableAST) throws -> String {
        let cols = ast.columns.map { SchemaColumn(id: $0.name, type: $0.type) }
        _ = try db.createTable(id: ast.name, columns: cols, primaryKey: ast.primaryKey)
        return "CREATE TABLE\n"
    }

    private func runCreateIndex(_ ast: CreateIndexAST) throws -> String {
        do {
            try db.createIndex(name: ast.name, tableId: ast.table, columnName: ast.column)
        } catch DatabaseError.unknownTable {
            throw SQLError.bind("no such table: \(ast.table)")
        } catch DatabaseError.unknownColumn {
            throw SQLError.bind("table `\(ast.table)` has no column `\(ast.column)`")
        } catch DatabaseError.duplicateIndex {
            throw SQLError.bind("index `\(ast.name)` already exists")
        } catch DatabaseError.duplicateKey {
            throw SQLError.bind("column `\(ast.column)` has duplicate values; cannot build a unique index")
        }
        return "CREATE INDEX\n"
    }

    private func runDropTable(name: String) throws -> String {
        guard let schema = db.schema else { throw SQLError.bind("no schema loaded") }
        let before = schema.tables.count
        schema.tables.removeAll { $0.id == name }
        if schema.tables.count == before {
            throw SQLError.bind("no such table: \(name)")
        }
        // Drop the table's indexes too.
        for meta in schema.indexes where meta.tableId == name {
            db.indexes[meta.segmentId] = nil
        }
        schema.indexes.removeAll { $0.tableId == name }
        try db.persistSchema()
        return "DROP TABLE\n"
    }

    private func runInsert(_ ast: InsertAST) throws -> String {
        guard let table = db.schema?.tables.first(where: { $0.id == ast.table }) else {
            throw SQLError.bind("no such table: \(ast.table)")
        }
        guard table.columns.count == ast.values.count else {
            throw SQLError.bind(
                "table `\(ast.table)` has \(table.columns.count) columns, got \(ast.values.count) values"
            )
        }
        var rendered: [String] = []
        for (col, lit) in zip(table.columns, ast.values) {
            switch (lit, col.type.tclass) {
            case (.int(let v), .integer):
                rendered.append(String(v))
            case (.string(let v), .char):
                rendered.append(v)
            case (.int(let v), .char):
                throw SQLError.bind("column `\(col.id)` is char but value is integer `\(v)`")
            case (.string(let v), .integer):
                throw SQLError.bind("column `\(col.id)` is integer but value is string `\(v)`")
            case (.double(let v), _):
                throw SQLError.bind("double literal `\(v)` is not yet supported for stored columns")
            case (.bool(let v), _):
                throw SQLError.bind("bool literal `\(v)` is not yet supported for stored columns")
            }
        }
        _ = try db.insert(table: table, values: rendered)
        return "INSERT 1\n"
    }

    private func runCopy(_ ast: CopyAST) throws -> String {
        guard let table = db.schema?.tables.first(where: { $0.id == ast.table }) else {
            throw SQLError.bind("no such table: \(ast.table)")
        }
        let url = URL(fileURLWithPath: ast.path)
        let count = try CSVLoader().load(into: table, db: db, fileURL: url, hasHeader: ast.hasHeader)
        return "COPY \(count)\n"
    }
}
