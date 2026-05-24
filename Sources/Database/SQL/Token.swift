/// Source location of a token, used for diagnostics.
public struct Span: Equatable, Sendable {
    public let line: Int
    public let column: Int
    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
    public static let zero = Span(line: 1, column: 1)
}

/// Lexical token.
public enum Token: Equatable, Sendable {
    // Query keywords.
    case select, from, whereKW, and, not, trueKW, falseKW
    // Set-operator keywords.
    case union, intersect, except, all
    // DDL / DML keywords.
    case create, table, drop, insert, into, values, copy, primary, key
    case index, on
    case csv, header
    // Identifier / literal payloads.
    case identifier(String)
    case integerLit(Int64)
    case doubleLit(Double)
    case stringLit(String)
    // Punctuation.
    case star, comma, dot, equal, notEqual, lparen, rparen, semicolon
    // Terminators.
    case eof
}

public struct TokenWithSpan: Equatable, Sendable {
    public let token: Token
    public let span: Span
    public init(token: Token, span: Span) {
        self.token = token
        self.span = span
    }
}
