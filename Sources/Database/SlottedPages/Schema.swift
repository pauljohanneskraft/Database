/// Schema description used by `SchemaSegment`, `SPSegment`, and `FSISegment`.
///
/// `SchemaTable` and `Schema` are reference types so the `FSISegment` /
/// `SPSegment` view of a table mutates in lockstep with whatever the schema
/// segment holds.

public struct SchemaType: Codable, Equatable, Sendable {
    public enum Class: String, Codable, Sendable {
        case integer
        case char
    }

    public let tclass: Class
    public let length: UInt32

    public init(tclass: Class, length: UInt32) {
        self.tclass = tclass
        self.length = length
    }

    public static let integer = SchemaType(tclass: .integer, length: 0)

    public static func char(length: UInt32) -> SchemaType {
        SchemaType(tclass: .char, length: length)
    }

    public var name: String {
        switch tclass {
        case .integer: return "integer"
        case .char: return "char"
        }
    }
}

public struct SchemaColumn: Codable, Equatable, Sendable {
    public let id: String
    public let type: SchemaType

    public init(id: String, type: SchemaType = .integer) {
        self.id = id
        self.type = type
    }
}

public final class SchemaTable: Codable {
    public let id: String
    public let columns: [SchemaColumn]
    public let primaryKey: [String]
    public let spSegment: UInt16
    public let fsiSegment: UInt16
    public var allocatedPages: UInt64

    public init(
        id: String,
        columns: [SchemaColumn],
        primaryKey: [String],
        spSegment: UInt16,
        fsiSegment: UInt16,
        allocatedPages: UInt64 = 0
    ) {
        self.id = id
        self.columns = columns
        self.primaryKey = primaryKey
        self.spSegment = spSegment
        self.fsiSegment = fsiSegment
        self.allocatedPages = allocatedPages
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case columns
        case primaryKey = "primary_key"
        case spSegment = "sp_segment"
        case fsiSegment = "fsi_segment"
        case allocatedPages = "allocated_pages"
    }
}

/// A single-column secondary index over a table, backed by a `BTree` in its
/// own segment. Values are `TID.rawValue`s. Only `int64` / `char16` keys are
/// supported, and indexes are unique (duplicate keys rejected at insert time).
public struct SchemaIndex: Codable, Equatable, Sendable {
    public enum KeyKind: String, Codable, Sendable {
        case int64
        case char16
    }

    public let name: String
    public let tableId: String
    public let columnIndex: Int
    public let segmentId: UInt16
    public let keyKind: KeyKind
    /// For `char16` keys: the column's declared width, so keys can be
    /// space-padded identically to stored values. Zero for `int64`.
    public let charLength: UInt32

    /// Persisted `BTree` header so a reopened index finds its real root rather
    /// than assuming page 0. Synced from the live tree at each schema write.
    public var root: UInt64
    public var rootLevel: UInt64
    public var maxPageId: UInt64

    public init(
        name: String,
        tableId: String,
        columnIndex: Int,
        segmentId: UInt16,
        keyKind: KeyKind,
        charLength: UInt32,
        root: UInt64,
        rootLevel: UInt64,
        maxPageId: UInt64
    ) {
        self.name = name
        self.tableId = tableId
        self.columnIndex = columnIndex
        self.segmentId = segmentId
        self.keyKind = keyKind
        self.charLength = charLength
        self.root = root
        self.rootLevel = rootLevel
        self.maxPageId = maxPageId
    }

    private enum CodingKeys: String, CodingKey {
        case name, tableId = "table_id", columnIndex = "column_index"
        case segmentId = "segment_id", keyKind = "key_kind", charLength = "char_length"
        case root, rootLevel = "root_level", maxPageId = "max_page_id"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try c.decode(String.self, forKey: .name)
        self.tableId = try c.decode(String.self, forKey: .tableId)
        self.columnIndex = try c.decode(Int.self, forKey: .columnIndex)
        self.segmentId = try c.decode(UInt16.self, forKey: .segmentId)
        self.keyKind = try c.decode(KeyKind.self, forKey: .keyKind)
        self.charLength = try c.decode(UInt32.self, forKey: .charLength)
        let initialRoot = UInt64(try c.decode(UInt16.self, forKey: .segmentId)) << 48
        self.root = try c.decodeIfPresent(UInt64.self, forKey: .root) ?? initialRoot
        self.rootLevel = try c.decodeIfPresent(UInt64.self, forKey: .rootLevel) ?? 0
        self.maxPageId = try c.decodeIfPresent(UInt64.self, forKey: .maxPageId) ?? initialRoot
    }
}

public final class Schema: Codable {
    public var tables: [SchemaTable]
    public var indexes: [SchemaIndex]

    public init(tables: [SchemaTable] = [], indexes: [SchemaIndex] = []) {
        self.tables = tables
        self.indexes = indexes
    }

    private enum CodingKeys: String, CodingKey {
        case tables
        case indexes
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tables = try container.decode([SchemaTable].self, forKey: .tables)
        // Tolerate schemas written before indexes existed.
        self.indexes = try container.decodeIfPresent([SchemaIndex].self, forKey: .indexes) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tables, forKey: .tables)
        try container.encode(indexes, forKey: .indexes)
    }
}
