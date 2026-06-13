import Foundation
import Testing
@testable import Database

/// End-to-end smoke tests across the SlottedPages / BTree / Operators boundary.
///
/// Each test runs in its own temporary cwd because `BufferManager` writes
/// segment files in the current working directory.

@Suite(.serialized)
struct IntegrationSuite {

    /// Two-column schema: (id integer, name char(16)). Char width is 16 to
    /// match `Register.char16`'s fixed payload.
    private static func twoColumnSchema() -> SchemaTable {
        SchemaTable(
            id: "people",
            columns: [
                SchemaColumn(id: "id", type: .integer),
                SchemaColumn(id: "name", type: .char(length: 16)),
            ],
            primaryKey: ["id"],
            spSegment: 10,
            fsiSegment: 11
        )
    }

    // MARK: - TableScan

    @Test func tableScanReadsAllRows() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            let schema = Schema(tables: [Self.twoColumnSchema()])
            try db.loadNewSchema(schema)
            let table = db.schema!.tables[0]

            let rows: [(Int32, String)] = [
                (3, "Carol           "),
                (1, "Alice           "),
                (2, "Bob             "),
            ]
            var tids: [TID] = []
            for (id, name) in rows {
                let tid = try db.insert(table: table, values: [String(id), name])
                tids.append(tid)
            }

            let scan = TableScan(
                segment: db.slottedPages[table.spSegment]!,
                table: table,
                tids: tids
            )
            let output = TextOutput()
            let printOp = Print(input: scan, stream: output)
            printOp.open()
            while printOp.next() {}
            printOp.close()
            #expect(output.contents == ("3,Carol           \n" + "1,Alice           \n" + "2,Bob             \n"))
        }
    }

    @Test func tableScanComposesWithProjectionAndSelect() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: [Self.twoColumnSchema()]))
            let table = db.schema!.tables[0]

            var tids: [TID] = []
            for (id, name) in [
                (1 as Int32, "Alice           "),
                (2 as Int32, "Bob             "),
                (3 as Int32, "Carol           "),
            ] {
                tids.append(try db.insert(table: table, values: [String(id), name]))
            }

            let scan = TableScan(
                segment: db.slottedPages[table.spSegment]!,
                table: table,
                tids: tids
            )
            let select = Select(
                input: scan,
                predicate: Select.PredicateAttributeInt64(attrIndex: 0, constant: 1, predicateType: .gt)
            )
            let projection = Projection(input: select, attrIndexes: [1])
            let output = TextOutput()
            let printOp = Print(input: projection, stream: output)
            printOp.open()
            while printOp.next() {}
            printOp.close()
            // Order from TableScan is insertion order; select keeps 2 & 3.
            #expect(output.contents == "Bob             \nCarol           \n")
        }
    }

    // MARK: - IndexScan

    @Test func indexScanLooksUpTID() throws {
        try TestSupport.withTempCwd {
            let bm = BufferManager(pageSize: 1024, pageCount: 32)
            let tree = BTree<UInt64>(segmentId: 5, bufferManager: bm)
            try tree.insert(100 as UInt64, 0xDEAD_BEEF)
            try tree.insert(200 as UInt64, 0xCAFE_F00D)
            try tree.insert(300 as UInt64, 0x1234_5678)

            // Hit.
            do {
                let scan = IndexScan {
                    guard let raw = try tree.lookup(UInt64(200)) else { return nil }
                    return Register.from(int: Int64(bitPattern: raw))
                }
                scan.open()
                #expect(scan.next())
                #expect(scan.getOutput()[0].asInt == Int64(bitPattern: 0xCAFE_F00D))
                #expect(!scan.next())
                scan.close()
            }
            // Miss.
            do {
                let scan = IndexScan {
                    guard let raw = try tree.lookup(UInt64(999)) else { return nil }
                    return Register.from(int: Int64(bitPattern: raw))
                }
                scan.open()
                #expect(!scan.next())
                scan.close()
            }
        }
    }

    // MARK: - Sort spillover

    /// Spills at least once and verifies the merged output equals the sorted
    /// input. Uses a tight memory budget so the in-memory batch is forced to
    /// flush.
    @Test func sortSpilloverProducesSortedOutput() throws {
        try TestSupport.withTempCwd {
            let count = 500
            let rows: [[OperatorsSuite.TestSource.ColumnValue]] = (0..<count).map { i in
                let v = Int64((i * 2654435761) & 0xFFFF)
                return [.int(v), .int(Int64(i))]
            }
            let source = OperatorsSuite.TestSource(
                layout: [.int64, .int64],
                rows: rows
            )
            // ~24 bytes per register; 2 columns → tiny budget forces frequent
            // spillover.
            let sort = Sort(
                input: source,
                criteria: [Sort.Criterion(attrIndex: 0, descending: false)],
                memoryBudgetBytes: 24 * 2 * 16
            )
            sort.open()
            var emitted: [Int64] = []
            while sort.next() {
                emitted.append(sort.getOutput()[0].asInt)
            }
            sort.close()

            #expect(emitted.count == count)
            let expected = rows.map { row in
                if case .int(let v) = row[0] { return v } else { return Int64(0) }
            }.sorted()
            #expect(emitted == expected)
        }
    }

    @Test func sortSpilloverMatchesInMemorySortForChar16() throws {
        try TestSupport.withTempCwd {
            let rows: [[OperatorsSuite.TestSource.ColumnValue]] = [
                [.string("zeta            ")],
                [.string("alpha           ")],
                [.string("mu              ")],
                [.string("delta           ")],
                [.string("epsilon         ")],
                [.string("beta            ")],
            ]
            let source = OperatorsSuite.TestSource(layout: [.char16], rows: rows)
            let sort = Sort(
                input: source,
                criteria: [Sort.Criterion(attrIndex: 0, descending: false)],
                memoryBudgetBytes: 24  // force every row to spill individually
            )
            sort.open()
            var out: [String] = []
            while sort.next() {
                out.append(sort.getOutput()[0].asString)
            }
            sort.close()
            #expect(
                out == [
                    "alpha           ",
                    "beta            ",
                    "delta           ",
                    "epsilon         ",
                    "mu              ",
                    "zeta            ",
                ])
        }
    }

    /// Wide rows (8 columns → 136-byte stride) forced through multiple merge
    /// passes, with a two-key ordering. Verifies the whole row travels with
    /// its sort key, not just the key field.
    @Test func sortSpilloverWideRowsMultiKey() throws {
        try TestSupport.withTempCwd {
            let count = 1000
            let layout: [OperatorsSuite.TestSource.Column] = Array(repeating: .int64, count: 8)
            let rows: [[OperatorsSuite.TestSource.ColumnValue]] = (0..<count).map { i in
                let primary = Int64((i * 48271) & 0xFF)  // many ties on key 0
                let secondary = Int64((i * 2654435761) & 0xFFFFFF)
                var cols: [OperatorsSuite.TestSource.ColumnValue] = [.int(primary), .int(secondary)]
                // Remaining columns carry a row signature so we can confirm the
                // payload stayed attached to its key.
                for c in 2..<8 { cols.append(.int(Int64(i &* 100 &+ c))) }
                return cols
            }
            let source = OperatorsSuite.TestSource(layout: layout, rows: rows)
            let sort = Sort(
                input: source,
                criteria: [
                    Sort.Criterion(attrIndex: 0, descending: false),
                    Sort.Criterion(attrIndex: 1, descending: true),
                ],
                memoryBudgetBytes: 136 * 8  // a handful of rows per run → real merges
            )
            sort.open()
            var emitted: [[Int64]] = []
            while sort.next() {
                emitted.append(sort.getOutput().map { $0.asInt })
            }
            sort.close()

            #expect(emitted.count == count)

            // Expected ordering: key0 asc, then key1 desc.
            let expected = rows.map {
                $0.map { v -> Int64 in
                    if case .int(let x) = v { return x } else { return 0 }
                }
            }.sorted { l, r in
                if l[0] != r[0] { return l[0] < r[0] }
                return l[1] > r[1]
            }
            #expect(emitted == expected)
        }
    }

    // MARK: - TableScan → BTree round-trip

    /// Insert rows through `Database`, build a `BTree<UInt64>`
    /// mapping `id → TID.rawValue`, then use `IndexScan` to fetch a TID and
    /// `TableScan` to read the row that TID points at.
    @Test func indexScanThenTableScanRoundTrip() throws {
        try TestSupport.withTempCwd {
            let db = Database(pageSize: 1024, pageCount: 32)
            try db.loadNewSchema(Schema(tables: [Self.twoColumnSchema()]))
            let table = db.schema!.tables[0]

            // Use a segment id distinct from the SP/FSI ones so the BTree
            // doesn't collide with table data on disk.
            let btree = BTree<UInt64>(segmentId: 7, bufferManager: db.bufferManager)
            var inserted: [(UInt64, String)] = []
            for (id, name) in [
                (UInt64(101), "one_o_one       "),
                (UInt64(202), "two_o_two       "),
                (UInt64(303), "three_o_three   "),
            ] {
                let tid = try db.insert(table: table, values: [String(id), name])
                try btree.insert(id, tid.rawValue)
                inserted.append((id, name))
            }

            // Use IndexScan to fetch the TID by id, then a small "1-tuple"
            // TableScan to decode the row.
            let lookupId: UInt64 = 202
            let indexScan = IndexScan {
                guard let raw = try btree.lookup(lookupId) else { return nil }
                return Register.from(int: Int64(bitPattern: raw))
            }
            indexScan.open()
            #expect(indexScan.next())
            let tidRaw = UInt64(bitPattern: indexScan.getOutput()[0].asInt)
            indexScan.close()

            let tid = TID(rawValue: tidRaw)
            let tableScan = TableScan(
                segment: db.slottedPages[table.spSegment]!,
                table: table,
                tids: [tid]
            )
            tableScan.open()
            #expect(tableScan.next())
            let row = tableScan.getOutput()
            #expect(row[0].asInt == 202)
            #expect(row[1].asString == "two_o_two       ")
            #expect(!tableScan.next())
            tableScan.close()
        }
    }
}
