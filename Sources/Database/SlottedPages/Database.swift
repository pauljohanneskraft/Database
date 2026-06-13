import Foundation

/// Convenience facade tying a buffer manager, a schema segment, and per-table
/// SP / FSI segments together. `insert` returns the TID; `readTuple` returns
/// the formatted columns as `[String]` rather than printing.
public final class Database {
    public let bufferManager: BufferManager
    public private(set) var schemaSegment: SchemaSegment?
    public private(set) var slottedPages: [UInt16: SPSegment] = [:]
    public private(set) var freeSpaceInventory: [UInt16: FSISegment] = [:]
    /// Live `BTree`-backed indexes, keyed by index segment id. Rebuilt from
    /// `schema.indexes` whenever a schema is loaded.
    public internal(set) var indexes: [UInt16: AnyIndex] = [:]

    /// Set when this `Database` owns a working-directory chdir guard from
    /// `open(directory:)` / `create(directory:)`. On deinit the previous cwd
    /// is restored.
    private var cwdGuard: CWDGuard?

    public init(pageSize: Int = 1024, pageCount: Int = 10) {
        self.bufferManager = BufferManager(pageSize: pageSize, pageCount: pageCount)
    }

    deinit {
        // Persist schema (including bumped `allocatedPages` and index headers)
        // before we drop the buffer manager and release the cwd. Best-effort.
        try? persistSchema()
        cwdGuard?.restore()
    }

    public var schema: Schema? {
        schemaSegment?.getSchema()
    }

    /// Syncs live index headers into the schema, then writes it to disk.
    func persistSchema() throws {
        syncIndexMetadata()
        try schemaSegment?.write()
    }

    public func loadNewSchema(_ schema: Schema) throws {
        if let existing = schemaSegment {
            try existing.write()
        }
        let segment = SchemaSegment(segmentId: 0, bufferManager: bufferManager)
        segment.setSchema(schema)
        schemaSegment = segment

        slottedPages.removeAll()
        freeSpaceInventory.removeAll()
        for table in schema.tables {
            let fsi = FSISegment(segmentId: table.fsiSegment, bufferManager: bufferManager, table: table)
            freeSpaceInventory[table.fsiSegment] = fsi
            let sp = SPSegment(
                segmentId: table.spSegment,
                bufferManager: bufferManager,
                schema: segment,
                fsi: fsi,
                table: table
            )
            slottedPages[table.spSegment] = sp
        }
        buildIndexes()
    }

    public func loadSchema(schemaSegmentId: UInt16) throws {
        if let existing = schemaSegment {
            try existing.write()
        }
        let segment = SchemaSegment(segmentId: schemaSegmentId, bufferManager: bufferManager)
        try segment.read()
        schemaSegment = segment

        slottedPages.removeAll()
        freeSpaceInventory.removeAll()
        guard let schema = segment.getSchema() else { return }
        for table in schema.tables {
            let fsi = FSISegment(segmentId: table.fsiSegment, bufferManager: bufferManager, table: table)
            freeSpaceInventory[table.fsiSegment] = fsi
            let sp = SPSegment(
                segmentId: table.spSegment,
                bufferManager: bufferManager,
                schema: segment,
                fsi: fsi,
                table: table
            )
            slottedPages[table.spSegment] = sp
        }
        buildIndexes()
    }

    /// Create a fresh database in `directory`. The directory is created if
    /// missing; the returned `Database` chdirs into it (so segment files
    /// land inside it) and restores cwd on deinit.
    public static func create(
        directory: URL,
        pageSize: Int = 1024,
        pageCount: Int = 64
    ) throws -> Database {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let guardObj = try CWDGuard.acquire(to: directory)
        let db = Database(pageSize: pageSize, pageCount: pageCount)
        db.cwdGuard = guardObj
        try db.loadNewSchema(Schema(tables: []))
        try db.schemaSegment?.write()
        return db
    }

    /// Open an existing database from `directory`. Reads the schema from
    /// segment 0 and rebuilds the per-table SP / FSI segments.
    public static func open(
        directory: URL,
        pageSize: Int = 1024,
        pageCount: Int = 64
    ) throws -> Database {
        let guardObj = try CWDGuard.acquire(to: directory)
        let db = Database(pageSize: pageSize, pageCount: pageCount)
        db.cwdGuard = guardObj
        try db.loadSchema(schemaSegmentId: 0)
        return db
    }

    /// Add a table to the live schema and create its SP/FSI segments. Picks
    /// segment ids automatically (10 + 2*N for SP, 11 + 2*N for FSI, where N
    /// is the current number of tables).
    @discardableResult
    public func createTable(
        id: String,
        columns: [SchemaColumn],
        primaryKey: [String] = []
    ) throws -> SchemaTable {
        guard let schemaSegment, let existingSchema = schemaSegment.getSchema() else {
            throw DatabaseError.invalidData
        }
        if existingSchema.tables.contains(where: { $0.id == id }) {
            throw DatabaseError.duplicateTable
        }
        let n = UInt16(existingSchema.tables.count)
        let spSeg = 10 + 2 * n
        let fsiSeg = 11 + 2 * n
        let table = SchemaTable(
            id: id,
            columns: columns,
            primaryKey: primaryKey,
            spSegment: spSeg,
            fsiSegment: fsiSeg
        )
        existingSchema.tables.append(table)
        let fsi = FSISegment(segmentId: fsiSeg, bufferManager: bufferManager, table: table)
        freeSpaceInventory[fsiSeg] = fsi
        let sp = SPSegment(
            segmentId: spSeg,
            bufferManager: bufferManager,
            schema: schemaSegment,
            fsi: fsi,
            table: table
        )
        slottedPages[spSeg] = sp
        try persistSchema()

        // Auto-index a single-column primary key on an indexable type.
        if primaryKey.count == 1,
            let pkCol = table.columns.first(where: { $0.id == primaryKey[0] }),
            pkCol.type.tclass == .integer || pkCol.type.tclass == .char
        {
            try createIndex(name: "pk_\(id)", tableId: id, columnName: pkCol.id)
        }
        return table
    }

    /// Insert a row whose values are given as strings, one per column. Returns
    /// the TID of the inserted record.
    @discardableResult
    public func insert(table: SchemaTable, values: [String]) throws -> TID {
        guard table.columns.count == values.count else {
            throw DatabaseError.invalidData
        }

        // Reject duplicates against any unique index before touching the SP
        // segment, so a rejected insert leaves no orphaned record.
        try checkUnique(table: table, values: values)

        var buffer: [UInt8] = []
        for (column, s) in zip(table.columns, values) {
            switch column.type.tclass {
            case .integer:
                let intValue = Int32(s) ?? 0
                withUnsafeBytes(of: intValue) { buffer.append(contentsOf: $0) }
            case .char:
                let length = Int(column.type.length)
                let chars = Array(s.utf8)
                for j in 0..<length {
                    buffer.append(j < chars.count ? chars[j] : 0x00)  // NUL fill
                }
            }
        }

        guard let sp = slottedPages[table.spSegment] else {
            throw DatabaseError.unknownTable
        }
        let tid = try sp.allocate(size: UInt32(buffer.count))
        try buffer.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                _ = try sp.write(tid: tid, from: UnsafeRawPointer(base), recordSize: UInt32(buffer.count))
            }
        }
        try updateIndexes(table: table, values: values, tid: tid)
        return tid
    }

    /// Read a row previously inserted with `insert`. Returns the columns as
    /// strings (integers are decoded; char content runs up to the NUL fill).
    public func readTuple(table: SchemaTable, tid: TID) throws -> [String] {
        guard let sp = slottedPages[table.spSegment] else {
            throw DatabaseError.unknownTable
        }
        var readBuffer = [UInt8](repeating: 0, count: 1024)
        let read: UInt32 = try readBuffer.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return 0 }
            return try sp.read(tid: tid, into: UnsafeMutableRawPointer(base), capacity: UInt32(buf.count))
        }

        var out: [String] = []
        var cursor = 0
        for column in table.columns {
            switch column.type.tclass {
            case .integer:
                if cursor + 4 > Int(read) { return out }
                let v = readBuffer.withUnsafeBytes { $0.load(fromByteOffset: cursor, as: Int32.self) }
                out.append(String(v))
                cursor += 4
            case .char:
                let length = Int(column.type.length)
                if cursor + length > Int(read) { return out }
                // Content runs up to the first NUL fill byte, or the whole field.
                var end = cursor
                let fieldEnd = cursor + length
                while end < fieldEnd && readBuffer[end] != 0 { end += 1 }
                out.append(String(decoding: readBuffer[cursor..<end], as: UTF8.self))
                cursor += length
            }
        }
        return out
    }
}

public enum DatabaseError: Error, Equatable, Sendable {
    case invalidData
    case unknownTable
    case unknownColumn
    case duplicateTable
    case duplicateIndex
    case duplicateKey
}

// MARK: - chdir guard

/// Serialises process-wide `chdir` so only one `Database.open` /
/// `Database.create` can hold the working directory at a time. Releases on
/// `restore()` (called from `Database.deinit`).
final class CWDGuard {
    private static let lock = NSLock()
    private let previous: String
    private var restored = false

    private init(previous: String) {
        self.previous = previous
    }

    static func acquire(to directory: URL) throws -> CWDGuard {
        lock.lock()
        let prev = FileManager.default.currentDirectoryPath
        guard FileManager.default.changeCurrentDirectoryPath(directory.path) else {
            lock.unlock()
            throw DatabaseError.invalidData
        }
        return CWDGuard(previous: prev)
    }

    func restore() {
        if restored { return }
        restored = true
        _ = FileManager.default.changeCurrentDirectoryPath(previous)
        CWDGuard.lock.unlock()
    }

    deinit {
        // Belt and braces.
        restore()
    }
}
