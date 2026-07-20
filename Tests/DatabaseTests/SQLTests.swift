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
        #expect(
            toks == [
                .select, .star, .from, .identifier("t"), .whereKW,
                .identifier("x"), .equal, .integerLit(1),
                .and, .identifier("y"), .equal, .integerLit(2),
                .semicolon, .eof,
            ])
    }

    @Test func lexerStringAndDottedIdent() throws {
        var lex = Lexer("select s.name from studenten s where s.name = 'Sokrates'")
        let toks = try lex.tokenize().map(\.token)
        #expect(
            toks == [
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
        #expect(
            toks == [
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
            if case .lex = e { /* ok */  } else { Issue.record("wrong error kind: \(e)") }
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
        guard case .column(let first) = ast.projections[0] else {
            Issue.record("expected a plain column projection")
            return
        }
        #expect(first.name == "name")
        #expect(first.relation == "s")
    }

    @Test func parserWhereSelection() throws {
        let ast = try Self.parseSelect("select * from studenten s where s.matrnr = 24002")
        #expect(ast.selections.count == 1)
        #expect(ast.joins.isEmpty)
        #expect(ast.selections[0].1 == .eq)
        if case .int(let v) = ast.selections[0].2 {
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
            if case .parse = e { /* ok */  } else { Issue.record("wrong error kind: \(e)") }
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
        guard case .column(let attr) = bound.projections[0] else {
            Issue.record("expected a plain column projection")
            return
        }
        #expect(attr.name == "name")
        #expect(attr.scanIndex == 0)
    }

    // MARK: - End-to-end (parse → plan → execute)

    @Test func endToEndSelectStarSingleTable() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Self.studentenSchema())
            let students = db.schema!.tables[0]
            try db.insert(table: students, values: ["24002", Self.padded("Xenokrates"), "18"])
            try db.insert(table: students, values: ["26120", Self.padded("Fichte"), "10"])
            try db.insert(table: students, values: ["29555", Self.padded("Feuerbach"), "2"])

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
            try db.insert(table: students, values: ["26120", Self.padded("Fichte"), "10"])
            try db.insert(table: students, values: ["29555", Self.padded("Feuerbach"), "2"])

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
            try db.insert(table: students, values: ["26120", Self.padded("Fichte"), "10"])
            try db.insert(table: hoeren, values: ["24002", "5001"])
            try db.insert(table: hoeren, values: ["24002", "5041"])
            try db.insert(table: hoeren, values: ["26120", "5022"])

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

    // MARK: - WHERE comparison operators

    @Test func endToEndWhereInequality() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: []))
            try Self.execute("create table t (a int);", on: db)
            for i in 1...5 {
                try Self.execute("insert into t values (\(i));", on: db)
            }
            #expect(Set(try Self.execute("select a from t where a < 3;", on: db).split(separator: "\n")) == ["1", "2"])
            #expect(
                Set(try Self.execute("select a from t where a >= 3;", on: db).split(separator: "\n"))
                    == ["3", "4", "5"])
            #expect(
                Set(try Self.execute("select a from t where a != 3;", on: db).split(separator: "\n"))
                    == ["1", "2", "4", "5"])
        }
    }

    // MARK: - DOUBLE / BOOL columns

    @Test func endToEndDoubleBoolColumns() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: []))
            try Self.execute("create table t (id int, price double, active bool);", on: db)
            try Self.execute("insert into t values (1, 3.5, true);", on: db)
            try Self.execute("insert into t values (2, 9.25, false);", on: db)

            let out = Set(try Self.execute("select * from t;", on: db).split(separator: "\n"))
            #expect(out == ["1,3.5,true", "2,9.25,false"])

            #expect(try Self.execute("select id from t where active = true;", on: db) == "1\n")
            #expect(try Self.execute("select id from t where price < 5.0;", on: db) == "1\n")
        }
    }

    // MARK: - HashJoin duplicate keys

    @Test func endToEndHashJoinDuplicateLeftKeys() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: []))
            try Self.execute("create table orders (oid int, cust int);", on: db)
            try Self.execute("create table payments (oid int, amount int);", on: db)
            // Two orders rows share `oid = 1` — the join must fan out both
            // against the single matching payment, not drop one.
            try Self.execute("insert into orders values (1, 100);", on: db)
            try Self.execute("insert into orders values (1, 200);", on: db)
            try Self.execute("insert into payments values (1, 50);", on: db)

            let out = try Self.execute(
                "select orders.cust, payments.amount from orders, payments where orders.oid = payments.oid;",
                on: db)
            #expect(Set(out.split(separator: "\n")) == ["100,50", "200,50"])
        }
    }

    // MARK: - GROUP BY / aggregates / ORDER BY

    @Test func endToEndGroupByAggregatesOrderBy() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: []))
            try Self.execute("create table employees (dept char(8), salary int);", on: db)
            try Self.execute("insert into employees values ('eng', 100);", on: db)
            try Self.execute("insert into employees values ('eng', 200);", on: db)
            try Self.execute("insert into employees values ('sales', 50);", on: db)

            let out = try Self.execute(
                "select dept, count(*), sum(salary) from employees group by dept order by dept;",
                on: db)
            #expect(out == "eng,2,300\n" + "sales,1,50\n")
        }
    }

    @Test func endToEndGroupByWithoutAggregateFunction() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: []))
            try Self.execute("create table t (dept char(8));", on: db)
            try Self.execute("insert into t values ('eng');", on: db)
            try Self.execute("insert into t values ('eng');", on: db)
            try Self.execute("insert into t values ('sales');", on: db)

            let out = try Self.execute("select dept from t group by dept;", on: db)
            #expect(Set(out.split(separator: "\n")) == ["eng", "sales"])
        }
    }

    @Test func endToEndOrderByPosition() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: []))
            try Self.execute("create table t (a int);", on: db)
            try Self.execute("insert into t values (3);", on: db)
            try Self.execute("insert into t values (1);", on: db)
            try Self.execute("insert into t values (2);", on: db)

            let out = try Self.execute("select a from t order by 1 desc;", on: db)
            #expect(out == "3\n2\n1\n")
        }
    }

    @Test func endToEndSumOnDoubleColumn() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: []))
            try Self.execute("create table sales (dept char(8), price double);", on: db)
            try Self.execute("insert into sales values ('eng', 3.5);", on: db)
            try Self.execute("insert into sales values ('eng', 9.25);", on: db)

            let out = try Self.execute("select dept, sum(price) from sales group by dept;", on: db)
            #expect(out == "eng,12.75\n")
        }
    }

    @Test func sumRejectsNonNumericColumn() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: []))
            try Self.execute("create table t (dept char(8));", on: db)

            #expect(throws: SQLError.self) {
                try Self.execute("select sum(dept) from t;", on: db)
            }
        }
    }

    @Test func endToEndCountStarOnEmptyTable() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: []))
            try Self.execute("create table empty_t (a int);", on: db)

            #expect(try Self.execute("select count(*) from empty_t;", on: db) == "0\n")
            #expect(try Self.execute("select sum(a) from empty_t;", on: db) == "0\n")
            // MIN/MAX over an empty ungrouped set would need NULL, which this
            // engine doesn't represent — 0 rows is today's documented result.
            #expect(try Self.execute("select min(a) from empty_t;", on: db) == "")
        }
    }

    @Test func reservedWordsUsableAsIdentifiers() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: []))
            try Self.execute("create table stats (id int, sum int, count int);", on: db)
            try Self.execute("insert into stats values (1, 10, 20);", on: db)

            #expect(try Self.execute("select sum, count from stats;", on: db) == "10,20\n")
            #expect(try Self.execute("select count(*) from stats;", on: db) == "1\n")
        }
    }

    @Test func primaryKeyOnDoubleColumnIsRejected() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: []))

            #expect(throws: DatabaseError.invalidData) {
                try Self.execute("create table pk_double (price double, primary key (price));", on: db)
            }
        }
    }

    @Test func doubleZeroAndNegativeZeroGroupTogether() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: []))
            try Self.execute("create table t (price double);", on: db)
            try Self.execute("insert into t values (0.0);", on: db)
            try Self.execute("insert into t values (-0.0);", on: db)

            let out = try Self.execute("select price, count(*) from t group by price;", on: db)
            #expect(out.split(separator: "\n").count == 1)
        }
    }

    @Test func createIndexOnMisalignedDoubleColumnDoesNotCrash() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: []))
            try Self.execute(
                "create table t2 (a int, flag bool, price double, b int, primary key (a));", on: db)
            try Self.execute("insert into t2 values (1, true, 3.5, 99);", on: db)
            try Self.execute("insert into t2 values (2, false, 9.25, 100);", on: db)

            // `price` sits at a non-8-aligned byte offset (after `a` and
            // `flag`); backfilling this index must not crash.
            try Self.execute("create index idx_b on t2 (b);", on: db)
            #expect(try Self.execute("select a from t2 where b = 100;", on: db) == "2\n")
        }
    }

    // MARK: - Helpers

    /// Parse a single SELECT statement and return its `QueryAST`. Fails the
    /// test if anything else came back.
    fileprivate static func parseSelect(_ source: String) throws -> QueryAST {
        var lex = Lexer(source)
        var parser = Parser(try lex.tokenize())
        guard case .select(let expr) = try parser.parse(),
            case .leaf(let q) = expr
        else {
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
