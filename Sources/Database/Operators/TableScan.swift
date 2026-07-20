/// Scans a list of TIDs from an `SPSegment`, decoding each tuple according to
/// the column types in the provided `SchemaTable`.
///
/// Integers are decoded as 4-byte little-endian `Int32` (matching the encoding
/// from `Database.insert`) and widened to `Int64` for the `Register`. Char
/// columns occupy their full declared width on disk; the content runs up to the
/// first NUL fill byte and is stored as the `Register`'s variable-length string.
/// Doubles are 8 raw bytes; bools are a single 0/1 byte.
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

        return decodeTuple(columns: table.columns, buffer: readBuffer, bytesRead: Int(bytesRead)) { i, value in
            output[i].assign(from: value)
        }
    }

    public func close() {
        output.removeAll()
        readBuffer.removeAll()
        index = 0
    }

    public func getOutput() -> [Register] { output }
}
