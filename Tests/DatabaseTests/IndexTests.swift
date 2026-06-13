import Foundation
import Testing
@testable import Database

/// Index infrastructure: auto-indexed primary keys, explicit CREATE INDEX,
/// uniqueness enforcement, and schema persistence across reopen.
@Suite(.serialized)
struct IndexSuite {

    private func freshDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("moderndbs_index_\(UUID().uuidString)")
    }

    // MARK: - Auto PK index

    @Test func primaryKeyIsAutoIndexed() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema())
            try db.createTable(
                id: "t",
                columns: [
                    SchemaColumn(id: "a", type: .integer),
                    SchemaColumn(id: "b", type: .char(length: 8)),
                ],
                primaryKey: ["a"]
            )
            let indexes = db.schema!.indexes
            #expect(indexes.count == 1)
            #expect(indexes[0].name == "pk_t")
            #expect(indexes[0].tableId == "t")
            #expect(indexes[0].columnIndex == 0)
            #expect(indexes[0].keyKind == .int64)
            // A live BTree handle exists for it.
            #expect(db.indexes[indexes[0].segmentId] != nil)
        }
    }

    @Test func compositePrimaryKeyIsNotAutoIndexed() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema())
            try db.createTable(
                id: "t",
                columns: [
                    SchemaColumn(id: "a", type: .integer),
                    SchemaColumn(id: "b", type: .integer),
                ],
                primaryKey: ["a", "b"]
            )
            #expect(db.schema!.indexes.isEmpty)
        }
    }

    // MARK: - CREATE INDEX statement

    @Test func createIndexStatementBuildsAndPopulates() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 64)
            try db.loadNewSchema(Schema())
            let exec = SQLExecutor(db: db)
            _ = try exec.execute("CREATE TABLE t (a INT, b CHAR(8));")
            _ = try exec.execute("INSERT INTO t VALUES (1, 'foo');")
            _ = try exec.execute("INSERT INTO t VALUES (2, 'bar');")

            let status = try exec.execute("CREATE INDEX idx_b ON t (b);")
            #expect(status == "CREATE INDEX\n")

            // The char index should resolve a stored value to its TID.
            guard let meta = db.schema!.indexes.first(where: { $0.name == "idx_b" }) else {
                Issue.record("idx_b not registered")
                return
            }
            #expect(meta.keyKind == .char16)
            let live = db.indexes[meta.segmentId]
            #expect(try live?.lookupTID(columnValue: "foo") != nil)
            #expect(try live?.lookupTID(columnValue: "bar") != nil)
            #expect(try live?.lookupTID(columnValue: "missing") == nil)
        }
    }

    @Test func insertAfterCreateIndexUpdatesTree() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 64)
            try db.loadNewSchema(Schema())
            let exec = SQLExecutor(db: db)
            _ = try exec.execute("CREATE TABLE t (a INT, b CHAR(8));")
            _ = try exec.execute("CREATE INDEX idx_a ON t (a);")
            _ = try exec.execute("INSERT INTO t VALUES (42, 'baz');")

            let meta = db.schema!.indexes.first { $0.name == "idx_a" }!
            let live = db.indexes[meta.segmentId]
            #expect(try live?.lookupTID(columnValue: "42") != nil)
        }
    }

    // MARK: - Uniqueness

    @Test func duplicatePrimaryKeyRejected() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 64)
            try db.loadNewSchema(Schema())
            let exec = SQLExecutor(db: db)
            _ = try exec.execute("CREATE TABLE t (a INT, PRIMARY KEY (a));")
            _ = try exec.execute("INSERT INTO t VALUES (7);")
            #expect(throws: DatabaseError.duplicateKey) {
                try exec.execute("INSERT INTO t VALUES (7);")
            }
        }
    }

    @Test func createIndexOnDuplicateValuesRejected() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 64)
            try db.loadNewSchema(Schema())
            let exec = SQLExecutor(db: db)
            _ = try exec.execute("CREATE TABLE t (a INT, b CHAR(8));")
            _ = try exec.execute("INSERT INTO t VALUES (1, 'dup');")
            _ = try exec.execute("INSERT INTO t VALUES (2, 'dup');")
            #expect(throws: SQLError.self) {
                try exec.execute("CREATE INDEX idx_b ON t (b);")
            }
            // The failed index left no registration behind.
            #expect(db.schema!.indexes.contains { $0.name == "idx_b" } == false)
        }
    }

    // MARK: - Persistence

    // MARK: - Planner wiring

    /// Parses + binds + plans `sql` against `db`, returning the operator tree
    /// root.
    private func plan(_ sql: String, db: Database) throws -> any Operator {
        var lexer = Lexer(sql)
        let tokens = try lexer.tokenize()
        var parser = Parser(tokens)
        guard case .select(let expr) = try parser.parse() else {
            throw SQLError.plan("not a SELECT")
        }
        let bound = try SemanticAnalysis().analyse(expr, schema: db.schema!)
        return try Planner(db: db).plan(bound)
    }

    @Test func plannerEmitsIndexScanForIndexedEquality() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 64)
            try db.loadNewSchema(Schema())
            let exec = SQLExecutor(db: db)
            _ = try exec.execute("CREATE TABLE t (a INT, b CHAR(8), PRIMARY KEY (a));")
            _ = try exec.execute("INSERT INTO t VALUES (1, 'x');")
            _ = try exec.execute("INSERT INTO t VALUES (2, 'y');")

            // `a` is the auto-indexed PK → leaf should be a TIDResolve over an
            // IndexScan, and the equality selection is consumed (no Select).
            let op = try plan("SELECT * FROM t WHERE a = 2;", db: db)
            #expect(op is TIDResolve)
        }
    }

    @Test func plannerFallsBackToTableScanForUnindexedEquality() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 64)
            try db.loadNewSchema(Schema())
            let exec = SQLExecutor(db: db)
            _ = try exec.execute("CREATE TABLE t (a INT, b CHAR(8), PRIMARY KEY (a));")
            _ = try exec.execute("INSERT INTO t VALUES (1, 'x');")

            // `b` is not indexed → TableScan leaf, equality applied as a Select.
            let op = try plan("SELECT * FROM t WHERE b = 'x';", db: db)
            #expect(op is Select)
        }
    }

    @Test func selectThroughIndexReturnsCorrectRow() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 64)
            try db.loadNewSchema(Schema())
            let exec = SQLExecutor(db: db)
            _ = try exec.execute("CREATE TABLE t (a INT, b CHAR(8), PRIMARY KEY (a));")
            for i in 0..<20 {
                _ = try exec.execute("INSERT INTO t VALUES (\(i), 'n\(i)');")
            }
            let out = try exec.execute("SELECT a FROM t WHERE a = 7;")
            #expect(out == "7\n")

            // A miss returns no rows.
            let miss = try exec.execute("SELECT a FROM t WHERE a = 999;")
            #expect(miss == "")
        }
    }

    @Test func selectThroughCharIndexReturnsCorrectRow() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 64)
            try db.loadNewSchema(Schema())
            let exec = SQLExecutor(db: db)
            _ = try exec.execute("CREATE TABLE t (a INT, b CHAR(8));")
            _ = try exec.execute("INSERT INTO t VALUES (10, 'apple');")
            _ = try exec.execute("INSERT INTO t VALUES (20, 'pear');")
            _ = try exec.execute("CREATE INDEX idx_b ON t (b);")

            let op = try plan("SELECT a FROM t WHERE b = 'pear';", db: db)
            #expect(op is Projection)  // Projection over TIDResolve over IndexScan

            let out = try exec.execute("SELECT a FROM t WHERE b = 'pear';")
            #expect(out == "20\n")
        }
    }

    @Test func indexSurvivesReopen() throws {
        let dir = freshDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Phase 1: create, populate, close (deinit persists schema + index).
        do {
            let db = try Database.create(directory: dir, pageSize: 1024, pageCount: 64)
            let exec = SQLExecutor(db: db)
            _ = try exec.execute("CREATE TABLE t (a INT, b CHAR(8), PRIMARY KEY (a));")
            for i in 0..<50 {
                _ = try exec.execute("INSERT INTO t VALUES (\(i), 'r\(i)');")
            }
        }

        // Phase 2: reopen and confirm the index metadata + contents survived.
        do {
            let db = try Database.open(directory: dir, pageSize: 1024, pageCount: 64)
            let metas = db.schema!.indexes
            #expect(metas.count == 1)
            let meta = metas[0]
            #expect(meta.name == "pk_t")
            let live = db.indexes[meta.segmentId]
            // Every key inserted before close resolves to a TID after reopen.
            for i in 0..<50 {
                #expect(try live?.lookupTID(columnValue: "\(i)") != nil, "missing key \(i)")
            }
            #expect(try live?.lookupTID(columnValue: "999") == nil)
        }
    }
}
