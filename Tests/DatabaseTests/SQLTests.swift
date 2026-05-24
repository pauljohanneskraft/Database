import Foundation
import Testing
@testable import Database

@Suite(.serialized)
struct SQLSuite {

    // MARK: - Shared fixtures

    private static func studentenSchema() -> Schema {
        Schema(tables: [
            SchemaTable(
                id: "studenten",
                columns: [
                    SchemaColumn(id: "matrnr", type: .integer),
                    SchemaColumn(id: "name", type: .char(length: 16)),
                    SchemaColumn(id: "semester", type: .integer),
                ],
                primaryKey: ["matrnr"],
                spSegment: 10,
                fsiSegment: 11
            ),
            SchemaTable(
                id: "hoeren",
                columns: [
                    SchemaColumn(id: "matrnr", type: .integer),
                    SchemaColumn(id: "vorlnr", type: .integer),
                ],
                primaryKey: ["matrnr", "vorlnr"],
                spSegment: 20,
                fsiSegment: 21
            ),
        ])
    }

    /// Pads `s` to 16 ASCII bytes with trailing spaces.
    private static func padded(_ s: String) -> String {
        if s.count >= 16 { return String(s.prefix(16)) }
        return s + String(repeating: " ", count: 16 - s.count)
    }

    // MARK: - Lexer

    @Test func lexerKeywordsAndPunctuation() throws {
        var lex = Lexer("SELECT * FROM t WHERE x = 1 AND y = 2;")
        let toks = try lex.tokenize().map(\.token)
        #expect(toks == [
            .select, .star, .from, .identifier("t"), .whereKW,
            .identifier("x"), .equal, .integerLit(1),
            .and, .identifier("y"), .equal, .integerLit(2),
            .semicolon, .eof,
        ])
    }

    @Test func lexerStringAndDottedIdent() throws {
        var lex = Lexer("select s.name from studenten s where s.name = 'Sokrates'")
        let toks = try lex.tokenize().map(\.token)
        #expect(toks == [
            .select, .identifier("s"), .dot, .identifier("name"),
            .from, .identifier("studenten"), .identifier("s"),
            .whereKW, .identifier("s"), .dot, .identifier("name"),
            .equal, .stringLit("Sokrates"),
            .eof,
        ])
    }

    @Test func lexerNumbers() throws {
        var lex = Lexer("1 2.5 -3 4e2 5.0e-1")
        let toks = try lex.tokenize().map(\.token)
        #expect(toks == [
            .integerLit(1),
            .doubleLit(2.5),
            .integerLit(-3),
            .doubleLit(400),
            .doubleLit(0.5),
            .eof,
        ])
    }

    @Test func lexerUnterminatedString() throws {
        var lex = Lexer("'unterminated")
        do {
            _ = try lex.tokenize()
            Issue.record("expected lex error")
        } catch let e as SQLError {
            if case .lex = e { /* ok */ } else { Issue.record("wrong error kind: \(e)") }
        }
    }

    @Test func lexerCaseInsensitiveKeywords() throws {
        var lex = Lexer("SeLeCt FrOm WhErE And tRuE")
        let toks = try lex.tokenize().map(\.token)
        #expect(toks == [.select, .from, .whereKW, .and, .trueKW, .eof])
    }

    // MARK: - Parser (SELECT)

    @Test func parserSelectStar() throws {
        let ast = try Self.parseSelect("select * from studenten s")
        #expect(ast.projections.isEmpty)
        #expect(ast.relations.count == 1)
        #expect(ast.relations[0].table == "studenten")
        #expect(ast.relations[0].alias == "s")
    }

    @Test func parserMultiAttr() throws {
        let ast = try Self.parseSelect("select s.name, s.semester from studenten s")
        #expect(ast.projections.count == 2)
        #expect(ast.projections[0].name == "name")
        #expect(ast.projections[0].relation == "s")
    }

    @Test func parserWhereSelection() throws {
        let ast = try Self.parseSelect("select * from studenten s where s.matrnr = 24002")
        #expect(ast.selections.count == 1)
        #expect(ast.joins.isEmpty)
        if case .int(let v) = ast.selections[0].1 {
            #expect(v == 24002)
        } else {
            Issue.record("expected int literal")
        }
    }

    @Test func parserWhereJoin() throws {
        let ast = try Self.parseSelect("select * from studenten s, hoeren h where s.matrnr = h.matrnr")
        #expect(ast.selections.isEmpty)
        #expect(ast.joins.count == 1)
        #expect(ast.joins[0].0.relation == "s")
        #expect(ast.joins[0].1.relation == "h")
    }

    @Test func parserSyntaxError() throws {
        var lex = Lexer("select from t")
        var parser = Parser(try lex.tokenize())
        do {
            _ = try parser.parse()
            Issue.record("expected parse error")
        } catch let e as SQLError {
            if case .parse = e { /* ok */ } else { Issue.record("wrong error kind: \(e)") }
        }
    }

    // MARK: - Parser (DDL/DML)

    @Test func parserCreateTable() throws {
        var lex = Lexer("create table studenten (matrnr int, name char(16), semester int);")
        var parser = Parser(try lex.tokenize())
        guard case .createTable(let ast) = try parser.parse() else {
            Issue.record("expected createTable statement")
            return
        }
        #expect(ast.name == "studenten")
        #expect(ast.columns.count == 3)
        #expect(ast.columns[0].type.tclass == .integer)
        #expect(ast.columns[1].type.tclass == .char)
        #expect(ast.columns[1].type.length == 16)
        #expect(ast.primaryKey.isEmpty)
    }

    @Test func parserCreateTableWithPrimaryKey() throws {
        var lex = Lexer("create table t (a int, b int, primary key (a));")
        var parser = Parser(try lex.tokenize())
        guard case .createTable(let ast) = try parser.parse() else {
            Issue.record("expected createTable statement")
            return
        }
        #expect(ast.primaryKey == ["a"])
        #expect(ast.columns.count == 2)
    }

    @Test func parserDropTable() throws {
        var lex = Lexer("drop table hoeren;")
        var parser = Parser(try lex.tokenize())
        guard case .dropTable(let name, _) = try parser.parse() else {
            Issue.record("expected dropTable statement")
            return
        }
        #expect(name == "hoeren")
    }

    @Test func parserInsertInto() throws {
        var lex = Lexer("insert into studenten values (24002, 'Xenokrates', 18);")
        var parser = Parser(try lex.tokenize())
        guard case .insertInto(let ast) = try parser.parse() else {
            Issue.record("expected insert statement")
            return
        }
        #expect(ast.table == "studenten")
        #expect(ast.values.count == 3)
        if case .int(let v) = ast.values[0] { #expect(v == 24002) }
        if case .string(let s) = ast.values[1] { #expect(s == "Xenokrates") }
    }

    @Test func parserCopyFrom() throws {
        var lex = Lexer("copy studenten from '/tmp/s.csv' csv header;")
        var parser = Parser(try lex.tokenize())
        guard case .copyFrom(let ast) = try parser.parse() else {
            Issue.record("expected copy statement")
            return
        }
        #expect(ast.table == "studenten")
        #expect(ast.path == "/tmp/s.csv")
        #expect(ast.hasHeader == true)
    }

    // MARK: - Semantic analysis

    @Test func semaUnknownRelation() throws {
        let ast = try Self.parseSelect("select x from no_such_table t")
        do {
            _ = try SemanticAnalysis().analyse(ast, schema: Self.studentenSchema())
            Issue.record("expected bind error")
        } catch let e as SQLError {
            #expect("\(e)".contains("unknown relation"))
        }
    }

    @Test func semaUnknownAttribute() throws {
        let ast = try Self.parseSelect("select s.nope from studenten s")
        do {
            _ = try SemanticAnalysis().analyse(ast, schema: Self.studentenSchema())
            Issue.record("expected bind error")
        } catch let e as SQLError {
            #expect("\(e)".contains("nope"))
        }
    }

    @Test func semaAmbiguousAttribute() throws {
        // `matrnr` exists on both studenten and hoeren.
        let ast = try Self.parseSelect("select matrnr from studenten s, hoeren h")
        do {
            _ = try SemanticAnalysis().analyse(ast, schema: Self.studentenSchema())
            Issue.record("expected ambiguity error")
        } catch let e as SQLError {
            #expect("\(e)".contains("ambiguous"))
        }
    }

    @Test func semaResolvesUnqualifiedAttribute() throws {
        // `name` is only on studenten.
        let ast = try Self.parseSelect("select name from studenten s, hoeren h")
        let bound = try SemanticAnalysis().analyse(ast, schema: Self.studentenSchema())
        #expect(bound.projections[0].name == "name")
        #expect(bound.projections[0].scanIndex == 0)
    }

    // MARK: - End-to-end (parse → plan → execute)

    @Test func endToEndSelectStarSingleTable() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Self.studentenSchema())
            let students = db.schema!.tables[0]
            try db.insert(table: students, values: ["24002", Self.padded("Xenokrates"), "18"])
            try db.insert(table: students, values: ["26120", Self.padded("Fichte"),     "10"])
            try db.insert(table: students, values: ["29555", Self.padded("Feuerbach"),  "2"])

            let out = try runQuery("select * from studenten s", on: db)
            let lines = out.split(separator: "\n").sorted()
            #expect(lines.count == 3)
            #expect(lines[0].hasPrefix("24002,Xenokrates"))
            #expect(lines[1].hasPrefix("26120,Fichte"))
            #expect(lines[2].hasPrefix("29555,Feuerbach"))
        }
    }

    @Test func endToEndWhereConstant() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Self.studentenSchema())
            let students = db.schema!.tables[0]
            try db.insert(table: students, values: ["24002", Self.padded("Xenokrates"), "18"])
            try db.insert(table: students, values: ["26120", Self.padded("Fichte"),     "10"])
            try db.insert(table: students, values: ["29555", Self.padded("Feuerbach"),  "2"])

            let out = try runQuery(
                "select s.name from studenten s where s.matrnr = 26120;",
                on: db
            )
            #expect(out == Self.padded("Fichte") + "\n")
        }
    }

    @Test func endToEndJoinTwoTables() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Self.studentenSchema())
            let students = db.schema!.tables[0]
            let hoeren = db.schema!.tables[1]
            try db.insert(table: students, values: ["24002", Self.padded("Xenokrates"), "18"])
            try db.insert(table: students, values: ["26120", Self.padded("Fichte"),     "10"])
            try db.insert(table: hoeren,   values: ["24002", "5001"])
            try db.insert(table: hoeren,   values: ["24002", "5041"])
            try db.insert(table: hoeren,   values: ["26120", "5022"])

            let out = try runQuery(
                "select s.name, h.vorlnr from studenten s, hoeren h where s.matrnr = h.matrnr",
                on: db
            )
            let lines = out.split(separator: "\n").sorted()
            #expect(lines.count == 3)
            #expect(lines.contains(where: { $0.hasPrefix(Self.padded("Xenokrates") + ",5001") }))
            #expect(lines.contains(where: { $0.hasPrefix(Self.padded("Xenokrates") + ",5041") }))
            #expect(lines.contains(where: { $0.hasPrefix(Self.padded("Fichte") + ",5022") }))
        }
    }

    // MARK: - DDL/DML end-to-end

    @Test func ddlCreateInsertSelect() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: []))

            try Self.execute("create table t (a int, b char(8));", on: db)
            try Self.execute("insert into t values (1, 'foo');", on: db)
            try Self.execute("insert into t values (2, 'bar');", on: db)

            let out = try Self.execute("select * from t;", on: db)
            let lines = out.split(separator: "\n").sorted()
            #expect(lines.count == 2)
            #expect(lines[0].hasPrefix("1,foo"))
            #expect(lines[1].hasPrefix("2,bar"))
        }
    }

    @Test func ddlDropTable() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: []))

            try Self.execute("create table t (a int);", on: db)
            #expect(db.schema!.tables.count == 1)
            try Self.execute("drop table t;", on: db)
            #expect(db.schema!.tables.isEmpty)
        }
    }

    @Test func ddlCopyFromCSV() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: []))
            try Self.execute("create table t (id int, name char(8));", on: db)

            // Write a CSV next to the cwd.
            let csv = "1,alice\n2,bob\n3,carol\n"
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("t.csv")
            try csv.write(to: url, atomically: true, encoding: .utf8)

            try Self.execute("copy t from '\(url.path)' csv;", on: db)
            let out = try Self.execute("select * from t;", on: db)
            let lines = out.split(separator: "\n").sorted()
            #expect(lines.count == 3)
            #expect(lines[0].hasPrefix("1,alice"))
            #expect(lines[2].hasPrefix("3,carol"))
        }
    }

    // MARK: - Helpers

    /// Parse a single SELECT statement and return its `QueryAST`. Fails the
    /// test if anything else came back.
    fileprivate static func parseSelect(_ source: String) throws -> QueryAST {
        var lex = Lexer(source)
        var parser = Parser(try lex.tokenize())
        guard case .select(let expr) = try parser.parse(),
              case .leaf(let q) = expr else {
            throw SQLError.parse(.zero, "expected single SELECT statement")
        }
        return q
    }

    /// Drive an arbitrary statement through the same executor the sql CLI uses.
    @discardableResult
    fileprivate static func execute(_ source: String, on db: Database) throws -> String {
        return try SQLExecutor(db: db).execute(source)
    }

    private func runQuery(_ source: String, on db: Database) throws -> String {
        return try Self.execute(source, on: db)
    }
}
