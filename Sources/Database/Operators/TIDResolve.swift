/// Resolves a stream of TIDs into full rows.
///
/// The input operator is expected to emit single-register rows holding a
/// `TID.rawValue` (as an `int64` register — the shape `IndexScan` produces with
/// the standard `Register.from(int: Int64(bitPattern:))` decoder). For each
/// such TID, `TIDResolve` reads the record from the `SPSegment` and emits the
/// table's columns as `N` registers, in declared order — identical in shape to
/// `TableScan`, so the planner can substitute one for the other.
public final class TIDResolve: UnaryOperator, Operator {
    public let segment: SPSegment
    public let table: SchemaTable

    private var output: [Register] = []
    private var readBuffer: [UInt8] = []

    public init(input: any Operator, segment: SPSegment, table: SchemaTable) {
        self.segment = segment
        self.table = table
        super.init(input: input)
    }

    public func open() {
        input.open()
        output = table.columns.map { _ in Register() }
        readBuffer = [UInt8](repeating: 0, count: max(64, segment.bufferManager.pageSize))
    }

    public func next() -> Bool {
        guard input.next() else { return false }
        let tid = TID(rawValue: UInt64(bitPattern: input.getOutput()[0].asInt))

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
                let slice = Array(readBuffer[cursor..<(cursor + length)])
                let s = String(bytes: slice, encoding: .utf8) ?? ""
                output[i].setString(s)
                cursor += length
            }
        }
        return true
    }

    public func close() {
        input.close()
        output.removeAll()
        readBuffer.removeAll()
    }

    public func getOutput() -> [Register] { output }
}
