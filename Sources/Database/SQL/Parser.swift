/// Recursive-descent parser over a token stream.
///
/// Grammar:
/// ```
/// query    ::= 'select' projList 'from' relList ('where' predList)? ';'?
/// projList ::= '*' | attrRef (',' attrRef)*
/// relList  ::= relation (',' relation)*
/// relation ::= IDENT (IDENT)?            -- table + optional alias
/// attrRef  ::= IDENT ('.' IDENT)?
/// predList ::= pred ('and' pred)*
/// pred     ::= attrRef '=' (attrRef | literal)
/// literal  ::= INTEGER | DOUBLE | STRING | 'true' | 'false'
/// ```
public struct Parser {
    private let tokens: [TokenWithSpan]
    private var pos: Int = 0

    public init(_ tokens: [TokenWithSpan]) {
        self.tokens = tokens
    }

    public mutating func parse() throws -> Statement {
        switch peek().token {
        case .select, .lparen:
            // A SELECT, or a parenthesised set-operation chain.
            let expr = try parseSelectExpr()
            try finishStatement()
            return .select(expr)
        case .create:
            // CREATE TABLE … | CREATE INDEX …
            if peek(offset: 1).token == .index {
                return .createIndex(try parseCreateIndex())
            }
            return .createTable(try parseCreateTable())
        case .drop:
            return try parseDropTable()
        case .insert:
            return .insertInto(try parseInsert())
        case .copy:
            return .copyFrom(try parseCopy())
        default:
            throw SQLError.parse(peek().span, "expected a statement keyword (SELECT/CREATE/DROP/INSERT/COPY)")
        }
    }

    // MARK: - SELECT (with set operators)

    /// `selectExpr := unionTerm ( (UNION|EXCEPT) [ALL] unionTerm )*`
    /// Left-associative; UNION/EXCEPT bind looser than INTERSECT.
    private mutating func parseSelectExpr() throws -> SelectExpr {
        var left = try parseUnionTerm()
        while peek().token == .union || peek().token == .except {
            let op: SetOpKind = peek().token == .union ? .union : .except
            advance()
            let all = consumeAllModifier()
            let right = try parseUnionTerm()
            left = .setOp(left: left, op: op, all: all, right: right)
        }
        return left
    }

    /// `unionTerm := selectAtom ( INTERSECT [ALL] selectAtom )*`
    private mutating func parseUnionTerm() throws -> SelectExpr {
        var left = try parseSelectAtom()
        while peek().token == .intersect {
            advance()
            let all = consumeAllModifier()
            let right = try parseSelectAtom()
            left = .setOp(left: left, op: .intersect, all: all, right: right)
        }
        return left
    }

    /// `selectAtom := '(' selectExpr ')' | singleSelect`
    private mutating func parseSelectAtom() throws -> SelectExpr {
        if peek().token == .lparen {
            advance()
            let inner = try parseSelectExpr()
            try expect(.rparen)
            return inner
        }
        return .leaf(try parseSelectCore())
    }

    private mutating func consumeAllModifier() -> Bool {
        if peek().token == .all {
            advance()
            return true
        }
        return false
    }

    /// Parses a single `SELECT … FROM … [WHERE …]` without consuming a
    /// statement terminator — the caller handles `;`/`)`/set-op keywords.
    private mutating func parseSelectCore() throws -> QueryAST {
        try expect(.select)
        let projections = try parseProjectionList()
        try expect(.from)
        let relations = try parseRelationList()

        var selections: [(QueryAST.AttrRef, QueryAST.Literal)] = []
        var joins: [(QueryAST.AttrRef, QueryAST.AttrRef)] = []

        if peek().token == .whereKW {
            advance()
            try parsePredicateList(into: &selections, joins: &joins)
        }
        return QueryAST(
            relations: relations,
            projections: projections,
            selections: selections,
            joins: joins
        )
    }

    // MARK: - CREATE TABLE

    private mutating func parseCreateTable() throws -> CreateTableAST {
        try expect(.create)
        try expect(.table)
        let name = try consumeIdentifier()
        try expect(.lparen)

        var columns: [CreateTableAST.Column] = []
        var primaryKey: [String] = []

        // Column list: comma-separated `<ident> <type>` items. The list can
        // be terminated by `)`, but `PRIMARY KEY (...)` may appear anywhere
        // among the items and the parser accepts it once.
        while true {
            if peek().token == .primary {
                advance()
                try expect(.key)
                try expect(.lparen)
                primaryKey.append(try consumeIdentifier().name)
                while peek().token == .comma {
                    advance()
                    primaryKey.append(try consumeIdentifier().name)
                }
                try expect(.rparen)
            } else {
                let col = try parseColumnDefinition()
                columns.append(col)
            }
            if peek().token == .comma {
                advance()
                continue
            }
            break
        }
        try expect(.rparen)
        try finishStatement()
        return CreateTableAST(
            name: name.name,
            nameSpan: name.span,
            columns: columns,
            primaryKey: primaryKey
        )
    }

    // MARK: - CREATE INDEX

    private mutating func parseCreateIndex() throws -> CreateIndexAST {
        try expect(.create)
        try expect(.index)
        let name = try consumeIdentifier()
        try expect(.on)
        let table = try consumeIdentifier()
        try expect(.lparen)
        let column = try consumeIdentifier()
        try expect(.rparen)
        try finishStatement()
        return CreateIndexAST(
            name: name.name,
            nameSpan: name.span,
            table: table.name,
            column: column.name
        )
    }

    private mutating func parseColumnDefinition() throws -> CreateTableAST.Column {
        let name = try consumeIdentifier()
        let typeIdent = try consumeIdentifier()
        let lowered = typeIdent.name.lowercased()
        switch lowered {
        case "int", "integer":
            return CreateTableAST.Column(name: name.name, type: .integer)
        case "char":
            try expect(.lparen)
            let length = try consumeInteger()
            try expect(.rparen)
            guard length > 0, length <= UInt32.max else {
                throw SQLError.parse(name.span, "char length out of range")
            }
            return CreateTableAST.Column(name: name.name, type: .char(length: UInt32(length)))
        default:
            throw SQLError.parse(typeIdent.span, "unknown column type `\(typeIdent.name)`")
        }
    }

    // MARK: - DROP TABLE

    private mutating func parseDropTable() throws -> Statement {
        try expect(.drop)
        try expect(.table)
        let name = try consumeIdentifier()
        try finishStatement()
        return .dropTable(name: name.name, span: name.span)
    }

    // MARK: - INSERT INTO

    private mutating func parseInsert() throws -> InsertAST {
        try expect(.insert)
        try expect(.into)
        let table = try consumeIdentifier()
        try expect(.values)
        try expect(.lparen)
        var values: [QueryAST.Literal] = []
        values.append(try parseLiteral())
        while peek().token == .comma {
            advance()
            values.append(try parseLiteral())
        }
        try expect(.rparen)
        try finishStatement()
        return InsertAST(table: table.name, tableSpan: table.span, values: values)
    }

    private mutating func parseLiteral() throws -> QueryAST.Literal {
        switch peek().token {
        case .integerLit(let v): advance(); return .int(v)
        case .doubleLit(let v):  advance(); return .double(v)
        case .stringLit(let v):  advance(); return .string(v)
        case .trueKW:            advance(); return .bool(true)
        case .falseKW:           advance(); return .bool(false)
        default:
            throw SQLError.parse(peek().span, "expected a literal value")
        }
    }

    // MARK: - COPY ... FROM

    private mutating func parseCopy() throws -> CopyAST {
        try expect(.copy)
        let table = try consumeIdentifier()
        try expect(.from)
        guard case .stringLit(let path) = peek().token else {
            throw SQLError.parse(peek().span, "expected a quoted file path after FROM")
        }
        advance()
        try expect(.csv)
        var hasHeader = false
        if peek().token == .header {
            advance()
            hasHeader = true
        }
        try finishStatement()
        return CopyAST(table: table.name, tableSpan: table.span, path: path, hasHeader: hasHeader)
    }

    // MARK: - Statement tail

    private mutating func finishStatement() throws {
        if peek().token == .semicolon { advance() }
        if peek().token != .eof {
            throw SQLError.parse(peek().span, "unexpected token after end of statement")
        }
    }

    private mutating func consumeInteger() throws -> Int64 {
        if case .integerLit(let v) = peek().token {
            advance()
            return v
        }
        throw SQLError.parse(peek().span, "expected integer literal")
    }

    // MARK: - Productions

    private mutating func parseProjectionList() throws -> [QueryAST.AttrRef] {
        if peek().token == .star {
            advance()
            return []
        }
        var out: [QueryAST.AttrRef] = []
        out.append(try parseAttrRef())
        while peek().token == .comma {
            advance()
            out.append(try parseAttrRef())
        }
        return out
    }

    private mutating func parseRelationList() throws -> [QueryAST.Relation] {
        var out: [QueryAST.Relation] = []
        out.append(try parseRelation())
        while peek().token == .comma {
            advance()
            out.append(try parseRelation())
        }
        return out
    }

    private mutating func parseRelation() throws -> QueryAST.Relation {
        let tableTok = try consumeIdentifier()
        // Optional alias: another bare identifier (no AS keyword in this dialect).
        var alias: String? = nil
        if case .identifier = peek().token {
            let aliasTok = try consumeIdentifier()
            alias = aliasTok.name
        }
        return QueryAST.Relation(table: tableTok.name, alias: alias, span: tableTok.span)
    }

    private mutating func parseAttrRef() throws -> QueryAST.AttrRef {
        let first = try consumeIdentifier()
        if peek().token == .dot {
            advance()
            let second = try consumeIdentifier()
            return QueryAST.AttrRef(relation: first.name, name: second.name, span: first.span)
        }
        return QueryAST.AttrRef(relation: nil, name: first.name, span: first.span)
    }

    private mutating func parsePredicateList(
        into selections: inout [(QueryAST.AttrRef, QueryAST.Literal)],
        joins: inout [(QueryAST.AttrRef, QueryAST.AttrRef)]
    ) throws {
        try parsePredicate(into: &selections, joins: &joins)
        while peek().token == .and {
            advance()
            try parsePredicate(into: &selections, joins: &joins)
        }
    }

    private mutating func parsePredicate(
        into selections: inout [(QueryAST.AttrRef, QueryAST.Literal)],
        joins: inout [(QueryAST.AttrRef, QueryAST.AttrRef)]
    ) throws {
        let lhs = try parseAttrRef()
        try expect(.equal)
        // RHS may be another attr ref (join) or a literal (selection).
        switch peek().token {
        case .identifier:
            let rhs = try parseAttrRef()
            joins.append((lhs, rhs))
        case .integerLit(let v):
            advance()
            selections.append((lhs, .int(v)))
        case .doubleLit(let v):
            advance()
            selections.append((lhs, .double(v)))
        case .stringLit(let v):
            advance()
            selections.append((lhs, .string(v)))
        case .trueKW:
            advance()
            selections.append((lhs, .bool(true)))
        case .falseKW:
            advance()
            selections.append((lhs, .bool(false)))
        default:
            throw SQLError.parse(peek().span, "expected attribute or literal after `=`")
        }
    }

    // MARK: - Token cursor

    private func peek(offset: Int = 0) -> TokenWithSpan {
        let i = pos + offset
        if i < tokens.count { return tokens[i] }
        return tokens.last ?? TokenWithSpan(token: .eof, span: .zero)
    }

    private mutating func advance() {
        if pos < tokens.count { pos += 1 }
    }

    private mutating func expect(_ token: Token) throws {
        if peek().token == token {
            advance()
            return
        }
        throw SQLError.parse(peek().span, "expected `\(describe(token))`, got `\(describe(peek().token))`")
    }

    private mutating func consumeIdentifier() throws -> (name: String, span: Span) {
        let cur = peek()
        if case .identifier(let s) = cur.token {
            advance()
            return (s, cur.span)
        }
        throw SQLError.parse(cur.span, "expected identifier")
    }

    private func describe(_ t: Token) -> String {
        switch t {
        case .select: return "SELECT"
        case .from: return "FROM"
        case .whereKW: return "WHERE"
        case .and: return "AND"
        case .not: return "NOT"
        case .trueKW: return "TRUE"
        case .falseKW: return "FALSE"
        case .union: return "UNION"
        case .intersect: return "INTERSECT"
        case .except: return "EXCEPT"
        case .all: return "ALL"
        case .create: return "CREATE"
        case .table: return "TABLE"
        case .drop: return "DROP"
        case .insert: return "INSERT"
        case .into: return "INTO"
        case .values: return "VALUES"
        case .copy: return "COPY"
        case .primary: return "PRIMARY"
        case .key: return "KEY"
        case .index: return "INDEX"
        case .on: return "ON"
        case .csv: return "CSV"
        case .header: return "HEADER"
        case .identifier(let s): return s
        case .integerLit(let v): return "\(v)"
        case .doubleLit(let v): return "\(v)"
        case .stringLit(let v): return "'\(v)'"
        case .star: return "*"
        case .comma: return ","
        case .dot: return "."
        case .equal: return "="
        case .notEqual: return "!="
        case .lparen: return "("
        case .rparen: return ")"
        case .semicolon: return ";"
        case .eof: return "<eof>"
        }
    }
}
