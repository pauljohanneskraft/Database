import Foundation
import Testing
@testable import Database

/// Slotted-page tests.
///
/// Each test runs in its own temporary cwd because `BufferManager` writes
/// segment files in the current working directory.

@Suite(.serialized)
struct SlottedPagesSuite {

    // MARK: - Helpers

    private static func tpchSchemaLight() -> Schema {
        Schema(tables: [
            SchemaTable(
                id: "customer",
                columns: [
                    SchemaColumn(id: "c_custkey", type: .integer),
                    SchemaColumn(id: "c_name", type: .char(length: 25)),
                    SchemaColumn(id: "c_address", type: .char(length: 40)),
                    SchemaColumn(id: "c_nationkey", type: .integer),
                    SchemaColumn(id: "c_phone", type: .char(length: 15)),
                    SchemaColumn(id: "c_acctbal", type: .integer),
                    SchemaColumn(id: "c_mktsegment", type: .char(length: 10)),
                    SchemaColumn(id: "c_comment", type: .char(length: 117)),
                ],
                primaryKey: ["c_custkey"],
                spSegment: 10,
                fsiSegment: 11
            ),
            SchemaTable(
                id: "nation",
                columns: [
                    SchemaColumn(id: "n_nationkey", type: .integer),
                    SchemaColumn(id: "n_name", type: .char(length: 25)),
                    SchemaColumn(id: "n_regionkey", type: .integer),
                    SchemaColumn(id: "n_comment", type: .char(length: 152)),
                ],
                primaryKey: ["n_nationkey"],
                spSegment: 20,
                fsiSegment: 21
            ),
            SchemaTable(
                id: "region",
                columns: [
                    SchemaColumn(id: "r_regionkey", type: .integer),
                    SchemaColumn(id: "r_name", type: .char(length: 25)),
                    SchemaColumn(id: "r_comment", type: .char(length: 152)),
                ],
                primaryKey: ["r_regionkey"],
                spSegment: 30,
                fsiSegment: 31
            ),
        ])
    }

    // MARK: - Schema

    @Test func schemaSetter() throws {
        try TestSupport.withTempCwd {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            let schemaSegment = SchemaSegment(segmentId: 0, bufferManager: bm)
            #expect(schemaSegment.getSchema() == nil)
            let schema = Self.tpchSchemaLight()
            schemaSegment.setSchema(schema)
            #expect(schemaSegment.getSchema() === schema)
        }
    }

    @Test func schemaSerialiseEmptySchema() throws {
        try TestSupport.withTempCwd {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            let segOut = SchemaSegment(segmentId: 0, bufferManager: bm)
            segOut.setSchema(Schema(tables: []))
            try segOut.write()
            let segIn = SchemaSegment(segmentId: 0, bufferManager: bm)
            try segIn.read()
            let loaded = try #require(segIn.getSchema())
            #expect(loaded.tables.isEmpty)
        }
    }

    @Test func schemaSerialiseTPCHLight() throws {
        try TestSupport.withTempCwd {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            let segOut = SchemaSegment(segmentId: 0, bufferManager: bm)
            segOut.setSchema(Self.tpchSchemaLight())
            try segOut.write()
            let segIn = SchemaSegment(segmentId: 0, bufferManager: bm)
            try segIn.read()
            let loaded = try #require(segIn.getSchema())
            #expect(loaded.tables.count == 3)

            let customer = loaded.tables[0]
            #expect(customer.id == "customer")
            #expect(customer.primaryKey == ["c_custkey"])
            #expect(customer.columns.count == 8)
            #expect(customer.columns[0].id == "c_custkey")
            #expect(customer.columns[0].type.tclass == .integer)
            #expect(customer.columns[1].id == "c_name")
            #expect(customer.columns[1].type.tclass == .char)
            #expect(customer.columns[1].type.length == 25)
            #expect(customer.columns[2].id == "c_address")
            #expect(customer.columns[2].type.length == 40)
            #expect(customer.columns[7].id == "c_comment")
            #expect(customer.columns[7].type.length == 117)

            let nation = loaded.tables[1]
            #expect(nation.id == "nation")
            #expect(nation.columns.count == 4)
            #expect(nation.columns[3].type.length == 152)
            #expect(nation.primaryKey == ["n_nationkey"])

            let region = loaded.tables[2]
            #expect(region.id == "region")
            #expect(region.columns.count == 3)
            #expect(region.primaryKey == ["r_regionkey"])
        }
    }

    // MARK: - FSI

    @Test func fsiEncoding() throws {
        try TestSupport.withTempCwd {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            let table = SchemaTable(
                id: "nation",
                columns: [SchemaColumn(id: "n_nationkey", type: .integer)],
                primaryKey: ["n_nationkey"],
                spSegment: 20,
                fsiSegment: 21
            )
            let fsi = FSISegment(segmentId: 1, bufferManager: bm, table: table)
            for i in 0..<UInt32(1024) {
                let encoded = fsi.encodeFreeSpace(i)
                let decoded = fsi.decodeFreeSpace(encoded)
                #expect(decoded <= i, "i=\(i) encoded=\(encoded) decoded=\(decoded)")
            }
        }
    }

    @Test func fsiFind() throws {
        try TestSupport.withTempCwd {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            let schemaSegment = SchemaSegment(segmentId: 0, bufferManager: bm)
            schemaSegment.setSchema(Self.tpchSchemaLight())
            let table = schemaSegment.getSchema()!.tables[0]
            let fsi = FSISegment(segmentId: table.fsiSegment, bufferManager: bm, table: table)
            let sp = SPSegment(
                segmentId: table.spSegment,
                bufferManager: bm,
                schema: schemaSegment,
                fsi: fsi,
                table: table
            )

            let recordSize: UInt32 = UInt32(MemoryLayout<UInt64>.size)
            let tid0 = try sp.allocate(size: recordSize)

            let page = try fsi.find(requiredSpace: recordSize)
            let p = try #require(page)
            #expect(p == BufferManager.segmentPageId(of: tid0.pageId(segmentId: 0)))
        }
    }

    @Test func fsiPersistence() throws {
        try TestSupport.withTempCwd {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            let schemaSegment = SchemaSegment(segmentId: 0, bufferManager: bm)
            schemaSegment.setSchema(Self.tpchSchemaLight())
            let table = schemaSegment.getSchema()!.tables[0]
            table.allocatedPages = 2

            var freePage: UInt64 = 0
            do {
                let fsi = FSISegment(segmentId: table.fsiSegment, bufferManager: bm, table: table)
                try fsi.update(targetPage: 0, freeSpace: 0)
                try fsi.update(targetPage: 1, freeSpace: 64)
                let page = try fsi.find(requiredSpace: 42)
                freePage = try #require(page)
                #expect(freePage == 1)
            }
            do {
                let fsi = FSISegment(segmentId: table.fsiSegment, bufferManager: bm, table: table)
                let page = try fsi.find(requiredSpace: 42)
                let p = try #require(page)
                #expect(p == freePage)
            }
        }
    }

    // MARK: - SPSegment

    @Test func spRecordAllocation() throws {
        try TestSupport.withTempCwd {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            let schemaSegment = SchemaSegment(segmentId: 0, bufferManager: bm)
            schemaSegment.setSchema(Self.tpchSchemaLight())
            let table = schemaSegment.getSchema()!.tables[0]
            let fsi = FSISegment(segmentId: table.fsiSegment, bufferManager: bm, table: table)
            let sp = SPSegment(
                segmentId: table.spSegment,
                bufferManager: bm,
                schema: schemaSegment,
                fsi: fsi,
                table: table
            )

            let max = UInt32(1024 - SlottedPage.slotSize - SlottedPage.headerSize)
            var i: UInt32 = 1
            while i < max {
                _ = try sp.allocate(size: i)
                i *= 2
            }
            _ = try sp.allocate(size: max)
        }
    }

    @Test func spRecordWriteRead() throws {
        try TestSupport.withTempCwd {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            let schemaSegment = SchemaSegment(segmentId: 0, bufferManager: bm)
            schemaSegment.setSchema(Self.tpchSchemaLight())
            let table = schemaSegment.getSchema()!.tables[0]
            let fsi = FSISegment(segmentId: table.fsiSegment, bufferManager: bm, table: table)
            let sp = SPSegment(
                segmentId: table.spSegment,
                bufferManager: bm,
                schema: schemaSegment,
                fsi: fsi,
                table: table
            )

            // The `-sizeof(TID)` reservation leaves room for one record plus
            // a potential redirect target.
            let max = 1024 - SlottedPage.slotSize - SlottedPage.headerSize - MemoryLayout<TID>.size
            var tids: [TID] = []
            var writeBuffer = [UInt8](repeating: 0, count: max)
            var readBuffer = [UInt8](repeating: 0, count: max)

            var size = 1
            while size < max {
                let s = UInt32(size)
                let tid = try sp.allocate(size: s)
                tids.append(tid)
                for j in 0..<size { writeBuffer[j] = UInt8(truncatingIfNeeded: size) }
                _ = try writeBuffer.withUnsafeBytes { wb -> UInt32 in
                    try sp.write(tid: tid, from: wb.baseAddress!, recordSize: s)
                }
                _ = try readBuffer.withUnsafeMutableBytes { rb -> UInt32 in
                    try sp.read(tid: tid, into: rb.baseAddress!, capacity: s)
                }
                #expect(
                    Array(writeBuffer.prefix(size)) == Array(readBuffer.prefix(size)),
                    "size=\(size) mismatch on first read")
                size *= 2
            }

            // Read everything again.
            var idx = 0
            size = 1
            while size < max {
                let s = UInt32(size)
                for j in 0..<size { writeBuffer[j] = UInt8(truncatingIfNeeded: size) }
                _ = try readBuffer.withUnsafeMutableBytes { rb -> UInt32 in
                    try sp.read(tid: tids[idx], into: rb.baseAddress!, capacity: s)
                }
                #expect(
                    Array(writeBuffer.prefix(size)) == Array(readBuffer.prefix(size)),
                    "size=\(size) mismatch on re-read")
                idx += 1
                size *= 2
            }
        }
    }

    @Test func spRecordWriteReadRedirect() throws {
        try TestSupport.withTempCwd {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            let schemaSegment = SchemaSegment(segmentId: 0, bufferManager: bm)
            schemaSegment.setSchema(Self.tpchSchemaLight())
            let table = schemaSegment.getSchema()!.tables[0]
            let fsi = FSISegment(segmentId: table.fsiSegment, bufferManager: bm, table: table)
            let sp = SPSegment(
                segmentId: table.spSegment,
                bufferManager: bm,
                schema: schemaSegment,
                fsi: fsi,
                table: table
            )

            let recordSize = UInt32(MemoryLayout<UInt64>.size)
            let maxRoom = 1024 - SlottedPage.headerSize
            let maxRecords = UInt64(maxRoom / (Int(recordSize) + SlottedPage.slotSize + MemoryLayout<TID>.size))
            let maxRecordSize = UInt32(1024 - SlottedPage.headerSize - SlottedPage.slotSize - MemoryLayout<TID>.size)
            var tids: [TID] = []

            // Fill the first page.
            for i in 0..<maxRecords {
                let tid = try sp.allocate(size: recordSize)
                tids.append(tid)
                var v = i
                _ = try withUnsafeBytes(of: &v) { buf -> UInt32 in
                    try sp.write(tid: tid, from: buf.baseAddress!, recordSize: recordSize)
                }
                var read: UInt64 = 0
                _ = try withUnsafeMutableBytes(of: &read) { buf -> UInt32 in
                    try sp.read(tid: tid, into: buf.baseAddress!, capacity: recordSize)
                }
                #expect(read == i)
            }

            // Resize a tid to require a redirect.
            let tid = tids.last!
            try sp.resize(tid: tid, newLength: maxRecordSize / 2)

            // Reading at recordSize should still see the prefix.
            var read: UInt64 = 0
            _ = try withUnsafeMutableBytes(of: &read) { buf -> UInt32 in
                try sp.read(tid: tid, into: buf.baseAddress!, capacity: recordSize)
            }
            #expect(read == maxRecords - 1)

            // Allocate more pages.
            for _ in 0..<(3 * maxRecords) {
                _ = try sp.allocate(size: recordSize)
            }
            try sp.resize(tid: tid, newLength: maxRecordSize)

            read = 0
            _ = try withUnsafeMutableBytes(of: &read) { buf -> UInt32 in
                try sp.read(tid: tid, into: buf.baseAddress!, capacity: recordSize)
            }
            #expect(read == maxRecords - 1)

            // Move back to original page.
            try sp.resize(tid: tid, newLength: recordSize)

            // Resize a few more times.
            try sp.resize(tid: tid, newLength: maxRecordSize)
            try sp.resize(tid: tid, newLength: maxRecordSize / 4)
            try sp.resize(tid: tid, newLength: maxRecordSize)
            try sp.resize(tid: tid, newLength: maxRecordSize)
            try sp.resize(tid: tid, newLength: maxRecordSize / 2)

            read = 0
            _ = try withUnsafeMutableBytes(of: &read) { buf -> UInt32 in
                try sp.read(tid: tid, into: buf.baseAddress!, capacity: recordSize)
            }
            #expect(read == maxRecords - 1)
        }
    }

    @Test func spRecordErase() throws {
        try TestSupport.withTempCwd {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            let schemaSegment = SchemaSegment(segmentId: 0, bufferManager: bm)
            schemaSegment.setSchema(Self.tpchSchemaLight())
            let table = schemaSegment.getSchema()!.tables[0]
            let fsi = FSISegment(segmentId: table.fsiSegment, bufferManager: bm, table: table)
            let sp = SPSegment(
                segmentId: table.spSegment,
                bufferManager: bm,
                schema: schemaSegment,
                fsi: fsi,
                table: table
            )

            let max = UInt32(1024 - SlottedPage.slotSize - SlottedPage.headerSize)
            let tid = try sp.allocate(size: max)

            let pageId = tid.pageId(segmentId: table.spSegment)
            do {
                let frame = try bm.fixPage(pageId: pageId, exclusive: true)
                let page = SlottedPage(buffer: frame.data)
                #expect(page.slotCount == 1)
                #expect(page.firstFreeSlot == 1)
                #expect(page.freeSpace == 0)
                #expect(page.dataStart == UInt32(SlottedPage.headerSize + SlottedPage.slotSize))
                bm.unfixPage(frame, isDirty: true)
            }

            try sp.erase(tid: tid)

            do {
                let frame = try bm.fixPage(pageId: pageId, exclusive: true)
                let page = SlottedPage(buffer: frame.data)
                #expect(page.slotCount == 0)
                #expect(page.firstFreeSlot == 0)
                #expect(page.freeSpace == UInt32(1024 - SlottedPage.headerSize))
                #expect(page.dataStart == 1024)
                bm.unfixPage(frame, isDirty: true)
            }
        }
    }

    @Test func spFuzzing() throws {
        try TestSupport.withTempCwd {
            let bm = BufferManager(pageSize: 1024, pageCount: 10)
            let schemaSegment = SchemaSegment(segmentId: 0, bufferManager: bm)
            schemaSegment.setSchema(Self.tpchSchemaLight())
            let table = schemaSegment.getSchema()!.tables[0]
            let fsi = FSISegment(segmentId: table.fsiSegment, bufferManager: bm, table: table)
            let sp = SPSegment(
                segmentId: table.spSegment,
                bufferManager: bm,
                schema: schemaSegment,
                fsi: fsi,
                table: table
            )

            var rng = SystemRandomNumberGenerator()
            let count = 100
            var records: [[UInt8]] = []
            var tids: [TID] = []
            var lengths: [Int] = []

            for _ in 0..<count {
                let size = Int.random(in: 1...250, using: &rng)
                let content = UInt8.random(in: 0...255, using: &rng)
                let buffer = [UInt8](repeating: content, count: size)

                let tid = try sp.allocate(size: UInt32(size))
                _ = try buffer.withUnsafeBytes { src in
                    try sp.write(tid: tid, from: src.baseAddress!, recordSize: UInt32(size))
                }
                lengths.append(size)
                tids.append(tid)
                records.append(buffer)
            }

            for i in 0..<lengths.count {
                var buf = [UInt8](repeating: 0, count: lengths[i])
                _ = try buf.withUnsafeMutableBytes { dst in
                    try sp.read(tid: tids[i], into: dst.baseAddress!, capacity: UInt32(lengths[i]))
                }
                #expect(buf == records[i], "INSERT failed at \(i)")
            }

            // Resize all records once.
            for i in 0..<count {
                let newSize = Int.random(in: 1...250, using: &rng)
                try sp.resize(tid: tids[i], newLength: UInt32(newSize))
                lengths[i] = min(lengths[i], newSize)
            }
            for i in 0..<lengths.count {
                var buf = [UInt8](repeating: 0, count: lengths[i])
                _ = try buf.withUnsafeMutableBytes { dst in
                    try sp.read(tid: tids[i], into: dst.baseAddress!, capacity: UInt32(lengths[i]))
                }
                #expect(buf == Array(records[i].prefix(lengths[i])), "RESIZE1 failed at \(i)")
            }

            // Resize all records again (now many are redirects).
            for i in 0..<count {
                let newSize = Int.random(in: 1...250, using: &rng)
                try sp.resize(tid: tids[i], newLength: UInt32(newSize))
                lengths[i] = min(lengths[i], newSize)
            }
            for i in 0..<lengths.count {
                var buf = [UInt8](repeating: 0, count: lengths[i])
                _ = try buf.withUnsafeMutableBytes { dst in
                    try sp.read(tid: tids[i], into: dst.baseAddress!, capacity: UInt32(lengths[i]))
                }
                #expect(buf == Array(records[i].prefix(lengths[i])), "RESIZE2 failed at \(i)")
            }

            // Erase ~half the records.
            var i = 0
            while i < lengths.count {
                if Bool.random(using: &rng) {
                    try sp.erase(tid: tids[i])
                    lengths.remove(at: i)
                    tids.remove(at: i)
                    records.remove(at: i)
                } else {
                    i += 1
                }
            }
            for i in 0..<lengths.count {
                var buf = [UInt8](repeating: 0, count: lengths[i])
                _ = try buf.withUnsafeMutableBytes { dst in
                    try sp.read(tid: tids[i], into: dst.baseAddress!, capacity: UInt32(lengths[i]))
                }
                #expect(buf == Array(records[i].prefix(lengths[i])), "ERASE failed at \(i)")
            }
        }
    }

    // MARK: - SlottedPage standalone

    @Test func slottedPageInitialize() throws {
        let pageSize = 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: pageSize, alignment: 16)
        defer { buffer.deallocate() }
        SlottedPage.initialize(buffer: buffer, pageSize: pageSize)
        let page = SlottedPage(buffer: buffer)
        #expect(page.slotCount == 0)
        #expect(page.firstFreeSlot == 0)
        #expect(page.dataStart == UInt32(pageSize))
        #expect(page.freeSpace == UInt32(pageSize - SlottedPage.headerSize))
    }

    @Test func slottedPageAllocateAndErase() throws {
        let pageSize = 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: pageSize, alignment: 16)
        defer { buffer.deallocate() }
        SlottedPage.initialize(buffer: buffer, pageSize: pageSize)
        var page = SlottedPage(buffer: buffer)
        let slotId = try page.allocate(dataSize: 100, pageSize: pageSize)
        #expect(slotId == 0)
        #expect(page.slotCount == 1)
        let s = page.slot(at: 0)
        #expect(s.size == 100)
        #expect(!s.isEmpty)
        #expect(!s.isRedirect)
        page.erase(slotId: 0)
        #expect(page.slotCount == 0)
        #expect(page.freeSpace == UInt32(pageSize - SlottedPage.headerSize))
    }

    /// Three 8-byte records, relocate the middle one to 16 bytes — the page
    /// has fragmented space
    /// to spare, so the relocation lands at the data-region front without
    /// triggering compactification.
    @Test func slottedPageRelocateWithoutBuffer() throws {
        let pageSize = 1024
        let recordSize: UInt32 = 8
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: pageSize, alignment: 16)
        defer { buffer.deallocate() }
        SlottedPage.initialize(buffer: buffer, pageSize: pageSize)
        var page = SlottedPage(buffer: buffer)
        #expect(page.slotCount == 0)
        #expect(page.firstFreeSlot == 0)
        #expect(page.dataStart == UInt32(pageSize))
        #expect(page.freeSpace == UInt32(pageSize - SlottedPage.headerSize))

        _ = try page.allocate(dataSize: recordSize, pageSize: pageSize)
        let slot2 = try page.allocate(dataSize: recordSize, pageSize: pageSize)
        _ = try page.allocate(dataSize: recordSize, pageSize: pageSize)
        #expect(page.slotCount == 3)
        #expect(page.firstFreeSlot == 3)
        #expect(page.dataStart == UInt32(pageSize) - 3 * recordSize)
        #expect(
            page.freeSpace == UInt32(pageSize) - 3 * recordSize - 3 * UInt32(SlottedPage.slotSize)
                - UInt32(SlottedPage.headerSize))

        page.relocate(slotId: slot2, dataSize: 2 * recordSize, pageSize: pageSize)
        #expect(page.slotCount == 3)
        #expect(page.firstFreeSlot == 3)
        #expect(page.dataStart == UInt32(pageSize) - 5 * recordSize)
        #expect(
            page.freeSpace == UInt32(pageSize) - 4 * recordSize - 3 * UInt32(SlottedPage.slotSize)
                - UInt32(SlottedPage.headerSize))
    }

    /// Fills the page to `freeSpace == 20` then relocates one slot to 28
    /// bytes — the in-place reuse path can't satisfy it, so `relocate` must
    /// compactify the data region (skipping the slot being relocated) and
    /// re-allocate from the
    /// freed gap.
    @Test func slottedPageRelocateWithCompactification() throws {
        let pageSize = 1024
        let recordSize: UInt32 = 8
        let maxRecords = (pageSize - SlottedPage.headerSize) / (Int(recordSize) + SlottedPage.slotSize)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: pageSize, alignment: 16)
        defer { buffer.deallocate() }
        SlottedPage.initialize(buffer: buffer, pageSize: pageSize)
        var page = SlottedPage(buffer: buffer)
        #expect(page.slotCount == 0)
        #expect(page.firstFreeSlot == 0)
        #expect(page.dataStart == UInt32(pageSize))
        #expect(page.freeSpace == UInt32(pageSize - SlottedPage.headerSize))

        let dummyRecords = UInt32(maxRecords - 1)
        for _ in 0..<dummyRecords {
            _ = try page.allocate(dataSize: recordSize, pageSize: pageSize)
        }

        #expect(page.slotCount == UInt16(dummyRecords))
        #expect(page.firstFreeSlot == UInt16(dummyRecords))
        #expect(page.dataStart == UInt32(pageSize) - dummyRecords * recordSize)
        #expect(
            page.freeSpace == UInt32(pageSize) - dummyRecords * recordSize - dummyRecords * UInt32(SlottedPage.slotSize)
                - UInt32(SlottedPage.headerSize))
        #expect(page.freeSpace == 20)

        page.relocate(slotId: 2, dataSize: 28, pageSize: pageSize)

        #expect(page.slotCount == UInt16(dummyRecords))
        #expect(page.firstFreeSlot == UInt16(dummyRecords))
        #expect(page.freeSpace == 0)
    }

    /// Audit for the TID-redirect one-hop bound. CLAUDE.md mandates
    /// that `SPSegment` never chain redirects; `read`/`write` rely on
    /// recursing exactly once, and any subsequent resize of an already-
    /// redirected TID must replace the existing redirect target rather
    /// than extend the chain.
    ///
    /// Drives the original TID through every `resize` branch (in-place
    /// grow → in-place→redirect, target-has-room, target-full→reallocate,
    /// shrink back to in-page) and asserts after each step that the chain
    /// from the original TID is at most one hop deep.
    @Test func spResizeRedirectChainStaysOneHop() throws {
        try TestSupport.withTempCwd {
            let bm = BufferManager(pageSize: 1024, pageCount: 16)
            let schemaSegment = SchemaSegment(segmentId: 0, bufferManager: bm)
            schemaSegment.setSchema(Self.tpchSchemaLight())
            let table = schemaSegment.getSchema()!.tables[0]
            let fsi = FSISegment(segmentId: table.fsiSegment, bufferManager: bm, table: table)
            let sp = SPSegment(
                segmentId: table.spSegment,
                bufferManager: bm,
                schema: schemaSegment,
                fsi: fsi,
                table: table
            )

            func chainHops(from tid: TID) throws -> Int {
                var current = tid
                var hops = 0
                while true {
                    let frame = try bm.fixPage(
                        pageId: current.pageId(segmentId: table.spSegment),
                        exclusive: false
                    )
                    let page = SlottedPage(buffer: frame.data)
                    let slot = page.slot(at: current.slot)
                    bm.unfixPage(frame, isDirty: false)
                    if slot.isRedirect {
                        hops += 1
                        // Defensive: if the implementation ever started
                        // chaining, this would loop forever; bail.
                        if hops > 10 { return hops }
                        current = slot.asRedirectTID
                        continue
                    }
                    return hops
                }
            }

            // Pack the first page so the original TID's home page can't
            // satisfy a grow — forces a redirect on the first resize.
            let recordSize = UInt32(MemoryLayout<UInt64>.size)
            let maxRoom = 1024 - SlottedPage.headerSize
            let perRecord = Int(recordSize) + SlottedPage.slotSize + MemoryLayout<TID>.size
            let firstPageRecords = UInt64(maxRoom / perRecord)
            let maxRecordSize = UInt32(1024 - SlottedPage.headerSize - SlottedPage.slotSize - MemoryLayout<TID>.size)

            var tids: [TID] = []
            for _ in 0..<firstPageRecords {
                tids.append(try sp.allocate(size: recordSize))
            }
            let target = tids.last!
            #expect(try chainHops(from: target) == 0)

            // In-page grow that still fits → no redirect.
            try sp.resize(tid: target, newLength: recordSize)
            #expect(try chainHops(from: target) == 0)

            // Grow beyond what the home page can hold → redirect introduced.
            try sp.resize(tid: target, newLength: maxRecordSize / 2)
            #expect(try chainHops(from: target) == 1)

            // Fill more pages so the redirect target eventually runs out
            // of room. Then grow again — exercises both the
            // target-has-room and target-full branches.
            for _ in 0..<(3 * Int(firstPageRecords)) {
                _ = try sp.allocate(size: recordSize)
            }
            try sp.resize(tid: target, newLength: maxRecordSize)
            #expect(try chainHops(from: target) == 1)

            // Shrink the redirect target. `SPSegment.resize` does not
            // collapse an established redirect back into the home page —
            // it just resizes the target in place. That's allowed under
            // the one-hop contract (chain length stays ≤ 1).
            try sp.resize(tid: target, newLength: recordSize)
            #expect(try chainHops(from: target) <= 1)

            // Bounce a few more times.
            for newLen: UInt32 in [maxRecordSize, maxRecordSize / 4, maxRecordSize, maxRecordSize / 2, recordSize] {
                try sp.resize(tid: target, newLength: newLen)
                #expect(try chainHops(from: target) <= 1)
            }
        }
    }
}
