import Foundation

public enum CSVError: Error, CustomStringConvertible {
    case ioError(String)
    case columnCountMismatch(line: Int, expected: Int, got: Int)
    case unterminatedQuote(line: Int)

    public var description: String {
        switch self {
        case .ioError(let m): return "csv io: \(m)"
        case .columnCountMismatch(let line, let exp, let got):
            return "csv line \(line): expected \(exp) columns, got \(got)"
        case .unterminatedQuote(let line):
            return "csv line \(line): unterminated quoted field"
        }
    }
}

public struct CSVLoader {
    public init() {}

    /// Loads `fileURL` into `table` on `db`. Returns the number of rows
    /// inserted. The first line is treated as a header iff `hasHeader` is
    /// true (skipped). Cells are parsed as RFC-4180-ish CSV: comma-delimited,
    /// double-quoted strings allowed, `""` inside a quoted string is an
    /// escaped quote.
    @discardableResult
    public func load(
        into table: SchemaTable,
        db: Database,
        fileURL: URL,
        hasHeader: Bool = false
    ) throws -> Int {
        let raw: String
        do {
            raw = try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw CSVError.ioError(error.localizedDescription)
        }

        var inserted = 0
        var lineNumber = 0
        var cursor = raw.startIndex
        var startedHeader = false

        while cursor < raw.endIndex {
            lineNumber += 1
            let (cells, next) = try Self.parseRow(raw, from: cursor, line: lineNumber)
            cursor = next
            if hasHeader && !startedHeader {
                startedHeader = true
                continue
            }
            if cells.isEmpty { continue }  // blank line
            guard cells.count == table.columns.count else {
                throw CSVError.columnCountMismatch(
                    line: lineNumber,
                    expected: table.columns.count,
                    got: cells.count
                )
            }
            try db.insert(table: table, values: cells)
            inserted += 1
        }
        return inserted
    }

    /// Parses one row starting at `from`. Advances past the row terminator
    /// (CR / LF / CRLF) and returns the cells plus the index of the next
    /// row.
    private static func parseRow(
        _ s: String,
        from: String.Index,
        line: Int
    ) throws -> (cells: [String], next: String.Index) {
        var cells: [String] = []
        var cur = from
        var field = ""
        var inQuotes = false

        while cur < s.endIndex {
            let c = s[cur]
            if inQuotes {
                if c == "\"" {
                    let nextIdx = s.index(after: cur)
                    if nextIdx < s.endIndex && s[nextIdx] == "\"" {
                        field.append("\"")
                        cur = s.index(after: nextIdx)
                        continue
                    }
                    inQuotes = false
                    cur = s.index(after: cur)
                    continue
                }
                field.append(c)
                cur = s.index(after: cur)
                continue
            }

            switch c {
            case "\"":
                inQuotes = true
                cur = s.index(after: cur)
            case ",":
                cells.append(field)
                field = ""
                cur = s.index(after: cur)
            case "\r":
                cur = s.index(after: cur)
                if cur < s.endIndex && s[cur] == "\n" {
                    cur = s.index(after: cur)
                }
                cells.append(field)
                return (cells, cur)
            case "\n":
                cur = s.index(after: cur)
                cells.append(field)
                return (cells, cur)
            default:
                field.append(c)
                cur = s.index(after: cur)
            }
        }

        if inQuotes {
            throw CSVError.unterminatedQuote(line: line)
        }
        // Final row without trailing newline.
        if !field.isEmpty || !cells.isEmpty {
            cells.append(field)
        }
        return (cells, cur)
    }
}
