/// Scans a list of TIDs from an `SPSegment`, decoding each tuple according to
/// the column types in the provided `SchemaTable`.
///
/// Integers are decoded as 4-byte little-endian `Int32` (matching the encoding
/// from `Database.insert`) and widened to `Int64` for the `Register`. Strings
/// are decoded as the column's full width on disk, then projected into the
/// fixed-16-byte `Register.char16` payload (truncated or padded by the
/// register itself).
///
/// Output register identities are stable across `open()`/`next()` cycles:
/// each output slot is constructed once in `open()`, then mutated in place
/// on every `next()` — matching the iterator-model contract.
public final class TableScan: Operator {
    public let segment: SPSegment
    public let table: SchemaTable
    public let tids: [TID]

    private var index = 0
    private var output: [Register] = []
    private var readBuffer: [UInt8] = []

    public init(segment: SPSegment, table: SchemaTable, tids: [TID]) {
        self.segment = segment
        self.table = table
        self.tids = tids
    }

    public func open() {
        output = table.columns.map { _ in Register() }
        readBuffer = [UInt8](repeating: 0, count: max(64, segment.bufferManager.pageSize))
    }

    public func next() -> Bool {
        guard index < tids.count else { return false }
        let tid = tids[index]
        index += 1

        let bytesRead: UInt32
        do {
            bytesRead = try readBuffer.withUnsafeMutableBufferPointer { buf -> UInt32 in
                guard let base = buf.baseAddress else { return 0 }
                return try segment.read(tid: tid, into: UnsafeMutableRawPointer(base), capacity: UInt32(buf.count))
            }
        } catch {
            return false
        }

        var cursor = 0
        for (i, column) in table.columns.enumerated() {
            switch column.type.tclass {
            case .integer:
                if cursor + 4 > Int(bytesRead) { return false }
                let v = readBuffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: Int32.self) }
                output[i].setInt(Int64(v))
                cursor += 4
            case .char:
                let length = Int(column.type.length)
                if cursor + length > Int(bytesRead) { return false }
                let endByte = min(cursor + length, Int(bytesRead))
                let slice = Array(readBuffer[cursor..<endByte])
                let s = String(bytes: slice, encoding: .utf8) ?? ""
                output[i].setString(s)
                cursor += length
            }
        }
        return true
    }

    public func close() {
        output.removeAll()
        readBuffer.removeAll()
        index = 0
    }

    public func getOutput() -> [Register] { output }
}
