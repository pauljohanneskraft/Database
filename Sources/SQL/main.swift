import ArgumentParser
import Foundation
import Database

@main
struct SQLShell: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sql",
        abstract: "Interactive SQL shell over an on-disk Database directory."
    )

    @ArgumentParser.Argument(help: "Database directory. Created automatically if it doesn't exist.")
    var directory: String

    @ArgumentParser.Flag(name: .long, help: "Require the database to already exist; fail otherwise.")
    var openOnly: Bool = false

    @ArgumentParser.Option(name: [.short, .long], help: "Run a single statement and exit (non-interactive).")
    var command: String?

    @ArgumentParser.Option(name: [.short, .long], help: "Run statements from a file and exit.")
    var file: String?

    init() {}

    func run() throws {
        let dbURL = URL(fileURLWithPath: directory)
        let db: Database
        if FileManager.default.fileExists(atPath: dbURL.path) {
            db = try Database.open(directory: dbURL)
        } else if openOnly {
            throw ValidationError("database directory does not exist: \(dbURL.path)")
        } else {
            db = try Database.create(directory: dbURL)
        }

        let executor = SQLExecutor(db: db)

        if let command {
            try Self.runOnce(command, executor: executor)
            return
        }
        if let file {
            let source = try String(contentsOf: URL(fileURLWithPath: file), encoding: .utf8)
            try Self.runScript(source, executor: executor)
            return
        }
        Self.runREPL(executor: executor)
    }

    // MARK: - Runners

    /// Run exactly one statement (no terminator required).
    static func runOnce(_ source: String, executor: SQLExecutor) throws {
        emit(executor: executor, source: source)
    }

    /// Run a sequence of `;`-terminated statements from one blob.
    static func runScript(_ source: String, executor: SQLExecutor) throws {
        for stmt in split(source) where !stmt.isEmpty {
            emit(executor: executor, source: stmt)
        }
    }

    /// Interactive REPL. Accumulates lines until a `;` is seen, then runs.
    static func runREPL(executor: SQLExecutor) {
        let prompt = "sql> "
        let cont = "...> "
        var pending = ""
        let isTTY = isatty(fileno(stdin)) != 0

        while true {
            if isTTY {
                let display = pending.isEmpty ? prompt : cont
                FileHandle.standardOutput.write(display.data(using: .utf8)!)
            }
            guard let line = readLine(strippingNewline: true) else {
                if !pending.isEmpty { emit(executor: executor, source: pending) }
                break
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if pending.isEmpty && (trimmed == "exit" || trimmed == "quit" || trimmed == "\\q") {
                break
            }
            pending += line + "\n"
            if line.contains(";") {
                emit(executor: executor, source: pending)
                pending = ""
            }
        }
    }

    // MARK: - I/O

    /// Execute one statement; print output to stdout, errors to stderr.
    static func emit(executor: SQLExecutor, source: String) {
        do {
            let out = try executor.execute(source)
            FileHandle.standardOutput.write(out.data(using: .utf8) ?? Data())
        } catch let error as SQLError {
            FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        } catch let error as CSVError {
            FileHandle.standardError.write("\(error)\n".data(using: .utf8)!)
        } catch {
            FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
        }
    }

    /// Split a script on top-level `;` boundaries. Respects string literals
    /// (single or double quoted) so semicolons inside quotes don't split.
    static func split(_ source: String) -> [String] {
        var stmts: [String] = []
        var current = ""
        var inQuote: Character? = nil
        for c in source {
            if let q = inQuote {
                current.append(c)
                if c == q { inQuote = nil }
                continue
            }
            if c == "'" || c == "\"" {
                inQuote = c
                current.append(c)
                continue
            }
            if c == ";" {
                current.append(c)
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { stmts.append(trimmed) }
                current = ""
                continue
            }
            current.append(c)
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { stmts.append(tail) }
        return stmts
    }
}
