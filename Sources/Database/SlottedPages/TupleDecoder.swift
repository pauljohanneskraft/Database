/// A single column's value as decoded from a raw tuple buffer.
enum DecodedTupleValue {
    case int(Int64)
    case string(String)
    case double(Double)
    case bool(Bool)
}

/// Shared decode loop for the on-disk tuple format written by
/// `Database.insert`: `Int32` little-endian integers, fixed-width NUL-padded
/// char fields, raw `Double` bytes, and single-byte bools, laid out
/// back-to-back in column order.
///
/// Walks `columns` against `buffer[0..<bytesRead]`, invoking `onColumn` for
/// each column that fully fits. Stops and returns `false` at the first
/// column that would read past `bytesRead`, without invoking `onColumn` for
/// it — callers that want partial results (like `Database.readTuple`) just
/// keep whatever `onColumn` already produced; callers that want all-or-
/// nothing (like `TableScan`/`TIDResolve`) propagate the `false`.
func decodeTuple(
    columns: [SchemaColumn],
    buffer: [UInt8],
    bytesRead: Int,
    onColumn: (Int, DecodedTupleValue) -> Void
) -> Bool {
    var cursor = 0
    for (i, column) in columns.enumerated() {
        switch column.type.tclass {
        case .integer:
            if cursor + 4 > bytesRead { return false }
            let v = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: Int32.self) }
            onColumn(i, .int(Int64(v)))
            cursor += 4
        case .char:
            let length = Int(column.type.length)
            if cursor + length > bytesRead { return false }
            // Content runs up to the first NUL fill byte, or the whole field.
            var end = cursor
            let fieldEnd = cursor + length
            while end < fieldEnd && buffer[end] != 0 { end += 1 }
            onColumn(i, .string(String(decoding: buffer[cursor..<end], as: UTF8.self)))
            cursor += length
        case .double:
            if cursor + 8 > bytesRead { return false }
            let v = buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: Double.self) }
            onColumn(i, .double(v))
            cursor += 8
        case .bool:
            if cursor + 1 > bytesRead { return false }
            onColumn(i, .bool(buffer[cursor] != 0))
            cursor += 1
        }
    }
    return true
}
