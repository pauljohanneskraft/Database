/// Index support for `Database`: a `BTree`-backed secondary index per
/// `SchemaIndex`. Keys are either `Int64` (integer columns) or `Char16` (char
/// columns); values are `TID.rawValue`s. Indexes are unique — inserting a
/// duplicate key throws `DatabaseError.duplicateKey`.

/// Type-erased handle over the two supported `BTree` key flavours. Encodes a
/// column's string value into the proper key before delegating.
public enum AnyIndex {
    case int64(BTree<Int64, UInt64>)
    case char16(BTree<Char16, UInt64>, length: Int)

    /// The integer encoding must match `Database.insert` / `TableScan`, which
    /// store integers as 4-byte `Int32` widened to `Int64`.
    static func int64Key(_ s: String) -> Int64 {
        Int64(Int32(s) ?? 0)
    }

    func contains(columnValue s: String) throws -> Bool {
        switch self {
        case .int64(let tree):
            return try tree.lookup(Self.int64Key(s)) != nil
        case .char16(let tree, let length):
            return try tree.lookup(Char16.padded(s, toLength: length)) != nil
        }
    }

    func lookupTID(columnValue s: String) throws -> UInt64? {
        switch self {
        case .int64(let tree):
            return try tree.lookup(Self.int64Key(s))
        case .char16(let tree, let length):
            return try tree.lookup(Char16.padded(s, toLength: length))
        }
    }

    func insert(columnValue s: String, tid: UInt64) throws {
        switch self {
        case .int64(let tree):
            try tree.insert(Self.int64Key(s), tid)
        case .char16(let tree, let length):
            try tree.insert(Char16.padded(s, toLength: length), tid)
        }
    }

    /// Live `(root, rootLevel, maxPageId)` header for persistence.
    var header: (root: UInt64, rootLevel: UInt64, maxPageId: UInt64) {
        switch self {
        case .int64(let tree): return (tree.root, tree.rootLevel, tree.maxPageId)
        case .char16(let tree, _): return (tree.root, tree.rootLevel, tree.maxPageId)
        }
    }

    /// Builds an `IndexScan` that emits the TID for `literal` (a single
    /// `int64` register holding `TID.rawValue`). Returns nil if the literal's
    /// kind doesn't match this index's key kind. The key is encoded exactly as
    /// it was at insert time so the lookup hits.
    func indexScan(forLiteral literal: QueryAST.Literal) -> (any Operator)? {
        let decode: (UInt64) -> Register = { Register.from(int: Int64(bitPattern: $0)) }
        switch self {
        case .int64(let tree):
            guard case .int(let v) = literal else { return nil }
            return IndexScan(tree: tree, key: Self.int64Key(String(v)), decode: decode)
        case .char16(let tree, let length):
            guard case .string(let s) = literal else { return nil }
            return IndexScan(tree: tree, key: Char16.padded(s, toLength: length), decode: decode)
        }
    }
}

extension Database {
    /// Index segment ids live well above the table SP/FSI range (10 + 2N …) so
    /// the two allocators never collide.
    private static let indexSegmentBase: UInt16 = 10_000

    private func allocateIndexSegmentId() -> UInt16 {
        let used = schema?.indexes.map { $0.segmentId }.max()
        return Swift.max(Database.indexSegmentBase, (used ?? (Database.indexSegmentBase - 1)) + 1)
    }

    /// (Re)build the live `AnyIndex` handles from `schema.indexes`, seeding each
    /// `BTree` with its persisted header so a reopened index finds its root.
    func buildIndexes() {
        indexes.removeAll()
        guard let schema else { return }
        for idx in schema.indexes {
            switch idx.keyKind {
            case .int64:
                let tree = BTree<Int64, UInt64>(segmentId: idx.segmentId, bufferManager: bufferManager)
                tree.root = idx.root
                tree.rootLevel = idx.rootLevel
                tree.maxPageId = idx.maxPageId
                indexes[idx.segmentId] = .int64(tree)
            case .char16:
                let tree = BTree<Char16, UInt64>(segmentId: idx.segmentId, bufferManager: bufferManager)
                tree.root = idx.root
                tree.rootLevel = idx.rootLevel
                tree.maxPageId = idx.maxPageId
                indexes[idx.segmentId] = .char16(tree, length: Int(idx.charLength))
            }
        }
    }

    /// Copies each live `BTree`'s header back into `schema.indexes` so the next
    /// schema write persists an accurate root pointer.
    func syncIndexMetadata() {
        guard let schema else { return }
        for i in schema.indexes.indices {
            if let live = indexes[schema.indexes[i].segmentId] {
                let h = live.header
                schema.indexes[i].root = h.root
                schema.indexes[i].rootLevel = h.rootLevel
                schema.indexes[i].maxPageId = h.maxPageId
            }
        }
    }

    /// All live indexes defined on `table`, paired with their column ordinal.
    func indexes(on table: SchemaTable) -> [(columnIndex: Int, index: AnyIndex)] {
        guard let schema else { return [] }
        return schema.indexes.compactMap { meta in
            guard meta.tableId == table.id, let live = indexes[meta.segmentId] else { return nil }
            return (meta.columnIndex, live)
        }
    }

    /// First index on `table` whose key column is `columnIndex`, if any.
    func index(on table: SchemaTable, columnIndex: Int) -> AnyIndex? {
        indexes(on: table).first { $0.columnIndex == columnIndex }?.index
    }

    /// Build a unique single-column index `name` on `table.column`. Backfills
    /// from existing rows. Throws if the column isn't indexable or contains
    /// duplicate values.
    @discardableResult
    public func createIndex(name: String, tableId: String, columnName: String) throws -> SchemaIndex {
        guard let schema else { throw DatabaseError.invalidData }
        guard let table = schema.tables.first(where: { $0.id == tableId }) else {
            throw DatabaseError.unknownTable
        }
        if schema.indexes.contains(where: { $0.name == name }) {
            throw DatabaseError.duplicateIndex
        }
        guard let columnIndex = table.columns.firstIndex(where: { $0.id == columnName }) else {
            throw DatabaseError.unknownColumn
        }
        let column = table.columns[columnIndex]
        let keyKind: SchemaIndex.KeyKind
        switch column.type.tclass {
        case .integer: keyKind = .int64
        case .char: keyKind = .char16
        }

        let segmentId = allocateIndexSegmentId()
        let live: AnyIndex
        switch keyKind {
        case .int64:
            live = .int64(BTree<Int64, UInt64>(segmentId: segmentId, bufferManager: bufferManager))
        case .char16:
            live = .char16(
                BTree<Char16, UInt64>(segmentId: segmentId, bufferManager: bufferManager),
                length: Int(column.type.length)
            )
        }
        indexes[segmentId] = live

        // Backfill from existing rows, enforcing uniqueness.
        if let sp = slottedPages[table.spSegment] {
            for tid in try sp.allTIDs() {
                let values = try readTuple(table: table, tid: tid)
                guard columnIndex < values.count else { continue }
                let value = values[columnIndex]
                if try live.contains(columnValue: value) {
                    indexes[segmentId] = nil
                    throw DatabaseError.duplicateKey
                }
                try live.insert(columnValue: value, tid: tid.rawValue)
            }
        }

        let h = live.header
        let meta = SchemaIndex(
            name: name,
            tableId: tableId,
            columnIndex: columnIndex,
            segmentId: segmentId,
            keyKind: keyKind,
            charLength: keyKind == .char16 ? column.type.length : 0,
            root: h.root,
            rootLevel: h.rootLevel,
            maxPageId: h.maxPageId
        )
        schema.indexes.append(meta)
        try persistSchema()
        return meta
    }

    /// Pre-insert uniqueness check across every index on `table`.
    func checkUnique(table: SchemaTable, values: [String]) throws {
        for (columnIndex, index) in indexes(on: table) {
            guard columnIndex < values.count else { continue }
            if try index.contains(columnValue: values[columnIndex]) {
                throw DatabaseError.duplicateKey
            }
        }
    }

    /// Post-insert index maintenance: add `tid` under each index's key.
    func updateIndexes(table: SchemaTable, values: [String], tid: TID) throws {
        for (columnIndex, index) in indexes(on: table) {
            guard columnIndex < values.count else { continue }
            try index.insert(columnValue: values[columnIndex], tid: tid.rawValue)
        }
    }
}
