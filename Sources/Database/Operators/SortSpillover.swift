#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#else
#error("Unsupported platform: SortSpillover requires a POSIX libc for memcpy")
#endif

/// Memory-budget-aware row sort built on the generic `externalSort`.
///
/// Rows in a single sort all share the same column layout, so each row
/// serialises to a fixed stride: per attribute, one kind tag byte plus a
/// payload of the attribute's wire width — 8 for `int64`/`double`, 1 for
/// `bool`, and the column's declared `CHAR(n)` width for `char16` (content,
/// NUL-filled). That fixed stride lets us hand the records straight to
/// `externalSort` without per-row length framing. The caller supplies the
/// per-attribute payload widths (`attributeWidths`) since a variable-length
/// char `Register` no longer carries its column width.
///
/// Usage: `write` each input row (buffered, flushed to a temp file in blocks
/// bounded by `memSize`), call `finish` to run the external sort, then stream
/// the sorted rows back with `next`.
final class SortSpillover {
    private let registerCount: Int
    /// Payload bytes per attribute (excludes the 1-byte tag).
    private let widths: [Int]
    /// Byte offset of each attribute's tag within a serialised row.
    private let offsets: [Int]
    private let rowStride: Int
    private let memSize: Int
    private let compare: (UnsafeRawPointer, UnsafeRawPointer) -> Bool

    private let input: PosixFile
    private var output: PosixFile?

    /// Bytes staged for the next flush to `input`.
    private var writeBuffer: [UInt8] = []
    private let flushThreshold: Int
    private var inputBytes = 0
    private var rowCount = 0

    /// Read cursor over the sorted `output` file.
    private var readOffset = 0
    private var rowScratch: [UInt8]
    private(set) var current: [Register] = []

    /// Tag(1) + payload offsets/stride for the given per-attribute payload
    /// widths.
    static func layout(_ attributeWidths: [Int]) -> (offsets: [Int], stride: Int) {
        var offsets: [Int] = []
        offsets.reserveCapacity(attributeWidths.count)
        var cursor = 0
        for w in attributeWidths {
            offsets.append(cursor)
            cursor += 1 + w
        }
        return (offsets, cursor)
    }

    private init(
        attributeWidths: [Int],
        memSize: Int,
        compare: @escaping (UnsafeRawPointer, UnsafeRawPointer) -> Bool,
        input: PosixFile
    ) {
        let (offsets, stride) = SortSpillover.layout(attributeWidths)
        self.registerCount = attributeWidths.count
        self.widths = attributeWidths
        self.offsets = offsets
        self.rowStride = stride
        // The external sort needs room for at least two records.
        self.memSize = max(memSize, 2 * stride)
        self.compare = compare
        self.input = input
        self.rowScratch = [UInt8](repeating: 0, count: stride)
        // Flush in blocks no larger than the sort budget, but always at least
        // one row.
        self.flushThreshold = max(stride, max(memSize, 2 * stride))
    }

    static func create(
        attributeWidths: [Int],
        memSize: Int,
        compare: @escaping (UnsafeRawPointer, UnsafeRawPointer) -> Bool
    ) throws -> SortSpillover {
        let file = try PosixFile.makeTemporary()
        return SortSpillover(attributeWidths: attributeWidths, memSize: memSize, compare: compare, input: file)
    }

    func write(_ row: [Register]) throws {
        precondition(row.count == registerCount, "row width must match the sort's register count")
        let base = writeBuffer.count
        writeBuffer.append(contentsOf: repeatElement(0, count: rowStride))
        writeBuffer.withUnsafeMutableBytes { raw in
            serialiseRow(row, into: raw.baseAddress!.advanced(by: base))
        }
        rowCount += 1
        if writeBuffer.count >= flushThreshold {
            try flush()
        }
    }

    private func flush() throws {
        if writeBuffer.isEmpty { return }
        try input.resize(inputBytes + writeBuffer.count)
        try writeBuffer.withUnsafeBufferPointer { buf in
            try input.writeBlock(UnsafeRawPointer(buf.baseAddress!), offset: inputBytes, size: buf.count)
        }
        inputBytes += writeBuffer.count
        writeBuffer.removeAll(keepingCapacity: true)
    }

    /// Materialises any buffered rows and runs the external sort. After this
    /// returns, `next` streams the sorted output.
    func finish() throws {
        try flush()
        let out = try PosixFile.makeTemporary()
        if rowCount > 0 {
            try externalSort(
                input: input,
                numElements: rowCount,
                elementSize: rowStride,
                output: out,
                memSize: memSize,
                compare: compare
            )
        }
        output = out
        readOffset = 0
    }

    /// Reads the next sorted row into `current`. Returns false when drained.
    func next() -> Bool {
        guard let output, readOffset + rowStride <= output.size else { return false }
        do {
            try rowScratch.withUnsafeMutableBytes { buf in
                try output.readBlock(offset: readOffset, size: rowStride, into: buf.baseAddress!)
            }
        } catch {
            return false
        }
        readOffset += rowStride
        current = rowScratch.withUnsafeBytes { raw in
            deserialiseRow(raw.baseAddress!)
        }
        return true
    }

    func close() {
        writeBuffer.removeAll()
        current.removeAll()
        output = nil
        readOffset = 0
        rowCount = 0
        inputBytes = 0
    }

    // MARK: - Row encoding

    private func serialiseRow(_ row: [Register], into base: UnsafeMutableRawPointer) {
        for (i, reg) in row.enumerated() {
            let offset = offsets[i]
            let width = widths[i]
            base.storeBytes(of: reg.kind.rawValue, toByteOffset: offset, as: UInt8.self)
            let payload = base.advanced(by: offset + 1)
            switch reg.kind {
            case .int64:
                var v = reg.asInt
                withUnsafeBytes(of: &v) { payload.copyMemory(from: $0.baseAddress!, byteCount: 8) }
            case .char16:
                // Content, NUL-filled to the attribute width (truncated if it
                // somehow overflows — content never exceeds the declared width).
                let utf8 = Array(reg.asString.utf8)
                payload.initializeMemory(as: UInt8.self, repeating: 0, count: width)
                for j in 0..<min(width, utf8.count) {
                    payload.storeBytes(of: utf8[j], toByteOffset: j, as: UInt8.self)
                }
            case .double:
                var v = reg.asDouble
                withUnsafeBytes(of: &v) { payload.copyMemory(from: $0.baseAddress!, byteCount: 8) }
            case .bool:
                var v: UInt8 = reg.asBool ? 1 : 0
                payload.copyMemory(from: &v, byteCount: 1)
            }
        }
    }

    private func deserialiseRow(_ base: UnsafeRawPointer) -> [Register] {
        var row: [Register] = []
        row.reserveCapacity(registerCount)
        for i in 0..<registerCount {
            let offset = offsets[i]
            let width = widths[i]
            let tag = base.load(fromByteOffset: offset, as: UInt8.self)
            let payload = base.advanced(by: offset + 1)
            let reg = Register()
            switch Register.Kind(rawValue: tag) {
            case .int64:
                reg.setInt(payload.loadUnaligned(as: Int64.self))
            case .double:
                reg.setDouble(payload.loadUnaligned(as: Double.self))
            case .bool:
                reg.setBool(payload.load(as: UInt8.self) != 0)
            case .char16, .none:
                // Content runs up to the first NUL fill byte within the field.
                var end = 0
                while end < width && payload.load(fromByteOffset: end, as: UInt8.self) != 0 { end += 1 }
                let buf = UnsafeBufferPointer<UInt8>(
                    start: payload.assumingMemoryBound(to: UInt8.self),
                    count: end
                )
                reg.setString(String(decoding: buf, as: UTF8.self))
            }
            row.append(reg)
        }
        return row
    }
}

// MARK: - Raw-row comparator

/// Builds a `<` predicate over two serialised rows for `externalSort`. Reads
/// only the register fields named by `criteria`; matches `Register`'s own
/// `Comparable` ordering per kind. `attributeWidths` is the same per-attribute
/// payload-width array the `SortSpillover` was created with.
func makeRowComparator(
    criteria: [Sort.Criterion],
    attributeWidths: [Int]
) -> (UnsafeRawPointer, UnsafeRawPointer) -> Bool {
    let (offsets, _) = SortSpillover.layout(attributeWidths)
    return { a, b in
        for criterion in criteria {
            let off = offsets[criterion.attrIndex]
            let width = attributeWidths[criterion.attrIndex]
            let order = compareRegisterBytes(a.advanced(by: off), b.advanced(by: off), width: width)
            if order == 0 { continue }
            let less = order < 0
            return criterion.descending ? !less : less
        }
        return false
    }
}

/// Three-way compare of two serialised registers (tag byte + payload). Returns
/// negative / zero / positive. Both sides are the same kind (schema guarantees
/// it), so the tag is read from `a` only. `width` is the char payload width.
@inline(__always)
private func compareRegisterBytes(_ a: UnsafeRawPointer, _ b: UnsafeRawPointer, width: Int) -> Int {
    let tag = a.load(as: UInt8.self)
    let pa = a.advanced(by: 1)
    let pb = b.advanced(by: 1)
    switch Register.Kind(rawValue: tag) {
    case .int64:
        let x = pa.loadUnaligned(as: Int64.self)
        let y = pb.loadUnaligned(as: Int64.self)
        return x < y ? -1 : (x > y ? 1 : 0)
    case .double:
        let x = pa.loadUnaligned(as: Double.self)
        let y = pb.loadUnaligned(as: Double.self)
        return x < y ? -1 : (x > y ? 1 : 0)
    case .bool:
        let x = pa.load(as: UInt8.self)
        let y = pb.load(as: UInt8.self)
        return Int(x) - Int(y)
    case .char16, .none:
        // NUL-filled bytes compare consistently with `Register`'s content
        // ordering, since the fill byte 0x00 is below any content byte.
        for i in 0..<width {
            let x = pa.load(fromByteOffset: i, as: UInt8.self)
            let y = pb.load(fromByteOffset: i, as: UInt8.self)
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }
}
