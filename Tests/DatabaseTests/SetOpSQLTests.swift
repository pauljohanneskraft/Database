import Foundation
import Testing
@testable import Database

/// Set operators wired through the SQL surface: lexing, parsing (chained +
/// parenthesised, with/without ALL), semantic union-compatibility, planner
/// operator selection, and end-to-end execution.
@Suite(.serialized)
struct SetOpSQLSuite {

    // MARK: - Lexer

    @Test func lexerSetOpKeywords() throws {
        var lex = Lexer("union all intersect except")
        let toks = try lex.tokenize().map(\.token)
        #expect(toks == [.union, .all, .intersect, .except, .eof])
    }

    // MARK: - Parser

    private func parseStatement(_ sql: String) throws -> Statement {
        var lex = Lexer(sql)
        var parser = Parser(try lex.tokenize())
        return try parser.parse()
    }

    @Test func parseChainedUnion() throws {
        guard
            case .select(let expr) = try parseStatement(
                "SELECT a FROM t UNION SELECT a FROM u;"
            )
        else { Issue.record("expected select"); return }
        guard case .setOp(_, let op, let all, _) = expr else {
            Issue.record("expected setOp at root"); return
        }
        #expect(op == .union)
        #expect(all == false)
    }

    @Test func parseUnionAll() throws {
        guard
            case .select(let expr) = try parseStatement(
                "SELECT a FROM t UNION ALL SELECT a FROM u;"
            )
        else { Issue.record("expected select"); return }
        guard case .setOp(_, .union, let all, _) = expr else {
            Issue.record("expected union setOp"); return
        }
        #expect(all == true)
    }

    @Test func parseParenthesised() throws {
        guard
            case .select(let expr) = try parseStatement(
                "(SELECT a FROM t) UNION (SELECT a FROM u);"
            )
        else { Issue.record("expected select"); return }
        guard case .setOp(let l, .union, _, let r) = expr else {
            Issue.record("expected union setOp"); return
        }
        if case .leaf = l {} else { Issue.record("left should be a leaf") }
        if case .leaf = r {} else { Issue.record("right should be a leaf") }
    }

    /// INTERSECT binds tighter than UNION: `A UNION B INTERSECT C` parses as
    /// `A UNION (B INTERSECT C)`.
    @Test func intersectBindsTighterThanUnion() throws {
        guard
            case .select(let expr) = try parseStatement(
                "SELECT a FROM t UNION SELECT a FROM u INTERSECT SELECT a FROM v;"
            )
        else { Issue.record("expected select"); return }
        guard case .setOp(let left, .union, _, let right) = expr else {
            Issue.record("root should be UNION"); return
        }
        if case .leaf = left {} else { Issue.record("UNION left should be a leaf (t)") }
        guard case .setOp(_, .intersect, _, _) = right else {
            Issue.record("UNION right should be an INTERSECT subtree"); return
        }
    }

    @Test func parenthesesOverridePrecedence() throws {
        // `(A UNION B) INTERSECT C` → root is INTERSECT.
        guard
            case .select(let expr) = try parseStatement(
                "(SELECT a FROM t UNION SELECT a FROM u) INTERSECT SELECT a FROM v;"
            )
        else { Issue.record("expected select"); return }
        guard case .setOp(let left, .intersect, _, _) = expr else {
            Issue.record("root should be INTERSECT"); return
        }
        guard case .setOp(_, .union, _, _) = left else {
            Issue.record("INTERSECT left should be a UNION subtree"); return
        }
    }

    // MARK: - Semantic analysis

    private static func twoTableSchema() -> Schema {
        Schema(tables: [
            SchemaTable(
                id: "t",
                columns: [SchemaColumn(id: "a", type: .integer), SchemaColumn(id: "b", type: .char(length: 8))],
                primaryKey: [], spSegment: 10, fsiSegment: 11
            ),
            SchemaTable(
                id: "u",
                columns: [SchemaColumn(id: "x", type: .integer)],
                primaryKey: [], spSegment: 12, fsiSegment: 13
            ),
        ])
    }

    @Test func semaRejectsArityMismatch() throws {
        let stmt = try parseStatement("SELECT a, b FROM t UNION SELECT x FROM u;")
        guard case .select(let expr) = stmt else { Issue.record("expected select"); return }
        #expect(throws: SQLError.self) {
            _ = try SemanticAnalysis().analyse(expr, schema: Self.twoTableSchema())
        }
    }

    @Test func semaRejectsTypeMismatch() throws {
        // t.b is char(8), u.x is integer → incompatible single-column union.
        let stmt = try parseStatement("SELECT b FROM t UNION SELECT x FROM u;")
        guard case .select(let expr) = stmt else { Issue.record("expected select"); return }
        #expect(throws: SQLError.self) {
            _ = try SemanticAnalysis().analyse(expr, schema: Self.twoTableSchema())
        }
    }

    @Test func semaAcceptsCompatibleColumns() throws {
        let stmt = try parseStatement("SELECT a FROM t UNION SELECT x FROM u;")
        guard case .select(let expr) = stmt else { Issue.record("expected select"); return }
        _ = try SemanticAnalysis().analyse(expr, schema: Self.twoTableSchema())
    }

    // MARK: - Planner operator selection

    private func plan(_ sql: String, db: Database) throws -> any Operator {
        let stmt = try parseStatement(sql)
        guard case .select(let expr) = stmt else { throw SQLError.plan("not a select") }
        let bound = try SemanticAnalysis().analyse(expr, schema: db.schema!)
        return try Planner(db: db).plan(bound)
    }

    @Test func plannerEmitsCorrectSetOperator() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 64)
            try db.loadNewSchema(Schema())
            let exec = SQLExecutor(db: db)
            _ = try exec.execute("CREATE TABLE t (a INT);")
            _ = try exec.execute("CREATE TABLE u (a INT);")

            #expect(try plan("SELECT a FROM t UNION SELECT a FROM u;", db: db) is Union)
            #expect(try plan("SELECT a FROM t UNION ALL SELECT a FROM u;", db: db) is UnionAll)
            #expect(try plan("SELECT a FROM t INTERSECT SELECT a FROM u;", db: db) is Intersect)
            #expect(try plan("SELECT a FROM t INTERSECT ALL SELECT a FROM u;", db: db) is IntersectAll)
            #expect(try plan("SELECT a FROM t EXCEPT SELECT a FROM u;", db: db) is Except)
            #expect(try plan("SELECT a FROM t EXCEPT ALL SELECT a FROM u;", db: db) is ExceptAll)
        }
    }

    // MARK: - End-to-end

    private func sortedLines(_ s: String) -> [String] {
        s.split(separator: "\n").map(String.init).sorted()
    }

    @Test func endToEndSetOperations() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 64)
            try db.loadNewSchema(Schema())
            let exec = SQLExecutor(db: db)
            _ = try exec.execute("CREATE TABLE t (a INT);")
            _ = try exec.execute("CREATE TABLE u (a INT);")
            for v in [1, 2, 3, 3] { _ = try exec.execute("INSERT INTO t VALUES (\(v));") }
            for v in [3, 4] { _ = try exec.execute("INSERT INTO u VALUES (\(v));") }

            // UNION (set): {1,2,3,4}
            #expect(
                sortedLines(
                    try exec.execute(
                        "SELECT a FROM t UNION SELECT a FROM u;"
                    )) == ["1", "2", "3", "4"])

            // UNION ALL (bag): 1,2,3,3 ++ 3,4
            #expect(
                sortedLines(
                    try exec.execute(
                        "SELECT a FROM t UNION ALL SELECT a FROM u;"
                    )) == ["1", "2", "3", "3", "3", "4"])

            // INTERSECT (set): {3}
            #expect(
                sortedLines(
                    try exec.execute(
                        "SELECT a FROM t INTERSECT SELECT a FROM u;"
                    )) == ["3"])

            // EXCEPT (set): t minus u = {1,2}
            #expect(
                sortedLines(
                    try exec.execute(
                        "SELECT a FROM t EXCEPT SELECT a FROM u;"
                    )) == ["1", "2"])
        }
    }

    @Test func endToEndParenthesisedPrecedence() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 64)
            try db.loadNewSchema(Schema())
            let exec = SQLExecutor(db: db)
            for name in ["t", "u", "v"] {
                _ = try exec.execute("CREATE TABLE \(name) (a INT);")
            }
            for v in [1, 2] { _ = try exec.execute("INSERT INTO t VALUES (\(v));") }
            for v in [2, 3] { _ = try exec.execute("INSERT INTO u VALUES (\(v));") }
            for v in [3] { _ = try exec.execute("INSERT INTO v VALUES (\(v));") }

            // Default precedence: t UNION (u INTERSECT v) = {1,2} ∪ ({2,3}∩{3}) = {1,2,3}
            #expect(
                sortedLines(
                    try exec.execute(
                        "SELECT a FROM t UNION SELECT a FROM u INTERSECT SELECT a FROM v;"
                    )) == ["1", "2", "3"])

            // Parenthesised: (t UNION u) INTERSECT v = {1,2,3} ∩ {3} = {3}
            #expect(
                sortedLines(
                    try exec.execute(
                        "(SELECT a FROM t UNION SELECT a FROM u) INTERSECT SELECT a FROM v;"
                    )) == ["3"])
        }
    }
}
