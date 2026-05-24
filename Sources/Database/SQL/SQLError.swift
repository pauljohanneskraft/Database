public enum SQLError: Error, Equatable, CustomStringConvertible, Sendable {
    case lex(Span, String)
    case parse(Span, String)
    case bind(String)
    case plan(String)

    public var description: String {
        switch self {
        case .lex(let span, let message):
            return "lex error \(span.line):\(span.column): \(message)"
        case .parse(let span, let message):
            return "parse error \(span.line):\(span.column): \(message)"
        case .bind(let message):
            return "bind error: \(message)"
        case .plan(let message):
            return "plan error: \(message)"
        }
    }
}
