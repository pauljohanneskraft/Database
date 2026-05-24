/// Hex-dump a buffer for failure diagnostics. Output: 16 bytes per line,
/// offset prefix in lowercase hex, byte values separated by single spaces.
public func hexDump(_ buffer: UnsafeRawBufferPointer, width: Int = 16) -> String {
    var out = ""
    var offset = 0
    while offset < buffer.count {
        let lineLen = Swift.min(width, buffer.count - offset)
        out += String(format: "%08x  ", offset)
        for i in 0..<lineLen {
            out += String(format: "%02x ", buffer[offset + i])
        }
        out += "\n"
        offset += lineLen
    }
    return out
}

public func hexDump(_ bytes: [UInt8], width: Int = 16) -> String {
    bytes.withUnsafeBytes { hexDump($0, width: width) }
}
