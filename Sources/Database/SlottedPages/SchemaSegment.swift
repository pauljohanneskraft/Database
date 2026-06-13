import Foundation

/// Persists a `Schema` into a buffer-manager segment.
///
/// Page-0 layout:
///   `[0:8)`   UInt64 length of the JSON payload
///   `[8:20)`  reserved for future metadata; reads/writes start at offset 20
///   `[20:N)`  JSON payload (continues onto pages 1, 2, ... when needed)
///
/// JSON field names are snake_case via `SchemaTable.CodingKeys`. The test
/// contract is round-trip fidelity — write a schema, read it back, get the
/// same schema. Foundation's `JSONEncoder` / `JSONDecoder` is used.
public final class SchemaSegment: Segment {
    public var schema: Schema?

    public override init(segmentId: UInt16, bufferManager: BufferManager) {
        super.init(segmentId: segmentId, bufferManager: bufferManager)
    }

    public func setSchema(_ newSchema: Schema?) {
        self.schema = newSchema
    }

    public func getSchema() -> Schema? {
        schema
    }

    /// Read the schema from disk into `self.schema`.
    public func read() throws {
        let pageSize = bufferManager.pageSize
        let firstPageId = UInt64(segmentId) << 48
        let firstFrame = try bufferManager.fixPage(pageId: firstPageId, exclusive: false)

        let schemaSize = Int(firstFrame.data.load(fromByteOffset: 0, as: UInt64.self))
        var buffer = [UInt8](repeating: 0, count: schemaSize)
        var bufferOffset = 0
        var remaining = schemaSize

        let firstChunk = Swift.min(remaining, pageSize - 20)
        if firstChunk > 0 {
            buffer.withUnsafeMutableBytes { dst in
                if let d = dst.baseAddress {
                    d.advanced(by: bufferOffset)
                        .copyMemory(from: firstFrame.data.advanced(by: 20), byteCount: firstChunk)
                }
            }
            bufferOffset += firstChunk
            remaining -= firstChunk
        }
        bufferManager.unfixPage(firstFrame, isDirty: false)

        var pid: UInt64 = 1
        while remaining > 0 {
            let pageId = (UInt64(segmentId) << 48) ^ pid
            let frame = try bufferManager.fixPage(pageId: pageId, exclusive: false)
            let n = Swift.min(remaining, pageSize)
            buffer.withUnsafeMutableBytes { dst in
                if let d = dst.baseAddress {
                    d.advanced(by: bufferOffset).copyMemory(from: frame.data, byteCount: n)
                }
            }
            bufferOffset += n
            remaining -= n
            bufferManager.unfixPage(frame, isDirty: false)
            pid += 1
        }

        if schemaSize == 0 {
            schema = Schema(tables: [])
            return
        }

        let data = Data(buffer)
        schema = try JSONDecoder().decode(Schema.self, from: data)
    }

    /// Write the schema (or a zero-length marker) to disk.
    public func write() throws {
        let pageSize = bufferManager.pageSize
        let firstPageId = UInt64(segmentId) << 48
        let firstFrame = try bufferManager.fixPage(pageId: firstPageId, exclusive: true)

        guard let schema = schema else {
            firstFrame.data.storeBytes(of: UInt64(0), toByteOffset: 0, as: UInt64.self)
            bufferManager.unfixPage(firstFrame, isDirty: true)
            return
        }

        let json = try JSONEncoder().encode(schema)
        let bytes = [UInt8](json)
        let schemaSize = bytes.count

        firstFrame.data.storeBytes(of: UInt64(schemaSize), toByteOffset: 0, as: UInt64.self)

        var bufferOffset = 0
        var remaining = schemaSize

        let firstChunk = Swift.min(remaining, pageSize - 20)
        if firstChunk > 0 {
            bytes.withUnsafeBytes { src in
                if let s = src.baseAddress {
                    firstFrame.data.advanced(by: 20).copyMemory(
                        from: s.advanced(by: bufferOffset), byteCount: firstChunk)
                }
            }
            bufferOffset += firstChunk
            remaining -= firstChunk
        }
        bufferManager.unfixPage(firstFrame, isDirty: true)

        var pid: UInt64 = 1
        while remaining > 0 {
            let pageId = (UInt64(segmentId) << 48) ^ pid
            let frame = try bufferManager.fixPage(pageId: pageId, exclusive: true)
            let n = Swift.min(remaining, pageSize)
            bytes.withUnsafeBytes { src in
                if let s = src.baseAddress {
                    frame.data.copyMemory(from: s.advanced(by: bufferOffset), byteCount: n)
                }
            }
            bufferOffset += n
            remaining -= n
            bufferManager.unfixPage(frame, isDirty: true)
            pid += 1
        }
    }
}
