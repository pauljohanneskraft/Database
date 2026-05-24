/// Hand-written SQL lexer. Recognises a small dialect: SELECT / FROM /
/// WHERE / AND / NOT / TRUE / FALSE (case-insensitive), identifiers,
/// integer / double / single- or double-quoted string literals, and the
/// punctuation needed for the parser (`*`, `,`, `.`, `=`, `!=`, `(`, `)`,
/// `;`). Whitespace is skipped; comments are not supported.
public struct Lexer {
    private let source: [Character]
    private var index: Int = 0
    private var line: Int = 1
    private var column: Int = 1

    public init(_ source: String) {
        self.source = Array(source)
    }

    public mutating func tokenize() throws -> [TokenWithSpan] {
        var out: [TokenWithSpan] = []
        while let t = try nextToken() {
            out.append(t)
            if t.token == .eof { break }
        }
        if out.last?.token != .eof {
            out.append(TokenWithSpan(token: .eof, span: currentSpan()))
        }
        return out
    }

    // MARK: - Core

    private mutating func nextToken() throws -> TokenWithSpan? {
        skipWhitespace()
        let start = currentSpan()
        guard let c = peek() else {
            return TokenWithSpan(token: .eof, span: start)
        }

        // Punctuation.
        switch c {
        case "*": advance(); return TokenWithSpan(token: .star, span: start)
        case ",": advance(); return TokenWithSpan(token: .comma, span: start)
        case ".": advance(); return TokenWithSpan(token: .dot, span: start)
        case "=": advance(); return TokenWithSpan(token: .equal, span: start)
        case "(": advance(); return TokenWithSpan(token: .lparen, span: start)
        case ")": advance(); return TokenWithSpan(token: .rparen, span: start)
        case ";": advance(); return TokenWithSpan(token: .semicolon, span: start)
        case "!":
            advance()
            if peek() == "=" {
                advance()
                return TokenWithSpan(token: .notEqual, span: start)
            }
            throw SQLError.lex(start, "expected `=` after `!`")
        case "'", "\"":
            return TokenWithSpan(token: try readString(quote: c, start: start), span: start)
        default:
            break
        }

        if c.isNumber || (c == "-" && (peek(offset: 1)?.isNumber ?? false)) {
            return TokenWithSpan(token: try readNumber(start: start), span: start)
        }

        if c.isLetter || c == "_" {
            return TokenWithSpan(token: readIdentOrKeyword(), span: start)
        }

        throw SQLError.lex(start, "unexpected character `\(c)`")
    }

    // MARK: - Literals

    private mutating func readString(quote: Character, start: Span) throws -> Token {
        advance() // opening quote
        var s = ""
        while let c = peek() {
            if c == quote {
                advance()
                return .stringLit(s)
            }
            if c == "\\", let next = peek(offset: 1) {
                advance(); advance()
                switch next {
                case "n": s.append("\n")
                case "t": s.append("\t")
                case "\\": s.append("\\")
                case "'": s.append("'")
                case "\"": s.append("\"")
                default: s.append(next)
                }
                continue
            }
            s.append(c)
            advance()
        }
        throw SQLError.lex(start, "unterminated string literal")
    }

    private mutating func readNumber(start: Span) throws -> Token {
        var s = ""
        if peek() == "-" {
            s.append("-")
            advance()
        }
        while let c = peek(), c.isNumber {
            s.append(c)
            advance()
        }
        // Optional fractional / exponent → double.
        var isDouble = false
        if peek() == "." {
            isDouble = true
            s.append(".")
            advance()
            while let c = peek(), c.isNumber {
                s.append(c)
                advance()
            }
        }
        if peek() == "e" || peek() == "E" {
            isDouble = true
            s.append("e")
            advance()
            if peek() == "+" || peek() == "-" {
                s.append(peek()!)
                advance()
            }
            while let c = peek(), c.isNumber {
                s.append(c)
                advance()
            }
        }
        if isDouble {
            guard let d = Double(s) else {
                throw SQLError.lex(start, "invalid double literal `\(s)`")
            }
            return .doubleLit(d)
        }
        guard let i = Int64(s) else {
            throw SQLError.lex(start, "invalid integer literal `\(s)`")
        }
        return .integerLit(i)
    }

    private mutating func readIdentOrKeyword() -> Token {
        var s = ""
        while let c = peek(), c.isLetter || c.isNumber || c == "_" {
            s.append(c)
            advance()
        }
        switch s.lowercased() {
        case "select": return .select
        case "from":   return .from
        case "where":  return .whereKW
        case "and":    return .and
        case "not":    return .not
        case "true":   return .trueKW
        case "false":  return .falseKW
        case "union":     return .union
        case "intersect": return .intersect
        case "except":    return .except
        case "all":       return .all
        case "create": return .create
        case "table":  return .table
        case "drop":   return .drop
        case "insert": return .insert
        case "into":   return .into
        case "values": return .values
        case "copy":   return .copy
        case "primary": return .primary
        case "key":    return .key
        case "index":  return .index
        case "on":     return .on
        case "csv":    return .csv
        case "header": return .header
        default:       return .identifier(s)
        }
    }

    // MARK: - Cursor helpers

    private func currentSpan() -> Span { Span(line: line, column: column) }

    private func peek(offset: Int = 0) -> Character? {
        let i = index + offset
        return i < source.count ? source[i] : nil
    }

    private mutating func advance() {
        guard index < source.count else { return }
        let c = source[index]
        index += 1
        if c == "\n" {
            line += 1
            column = 1
        } else {
            column += 1
        }
    }

    private mutating func skipWhitespace() {
        while let c = peek(), c.isWhitespace {
            advance()
        }
    }
}
