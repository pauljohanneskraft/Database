import Testing
@testable import Database

private let MEM_1KiB = 1 << 10
private let MEM_1MiB = 1 << 20

// MARK: - Helpers

private func bytes(from values: [UInt64]) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: values.count * 8)
    bytes.withUnsafeMutableBytes { dst in
        values.withUnsafeBytes { src in
            if let s = src.baseAddress, let d = dst.baseAddress {
                d.copyMemory(from: s, byteCount: values.count * 8)
            }
        }
    }
    return bytes
}

private func values(from file: MemoryFile) -> [UInt64] {
    let count = file.contents.count / 8
    var out = [UInt64](repeating: 0, count: count)
    file.contents.withUnsafeBytes { src in
        out.withUnsafeMutableBytes { dst in
            if let s = src.baseAddress, let d = dst.baseAddress, count > 0 {
                d.copyMemory(from: s, byteCount: count * 8)
            }
        }
    }
    return out
}

/// Reproducible LCG-style PRNG. Only `sort(input) == sort(output)` is
/// asserted, so any deterministic generator is fine.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z &>> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z &>> 31)
    }
}

private func makeRandomNumbers(count: Int) -> (values: [UInt64], input: MemoryFile) {
    var rng = SeededGenerator(seed: 0)
    var values = [UInt64]()
    values.reserveCapacity(count)
    for _ in 0..<count {
        values.append(UInt64.random(in: .min ... .max, using: &rng))
    }
    return (values, MemoryFile(contents: bytes(from: values)))
}

// MARK: - Fixed cases

@Test func emptyFile() throws {
    let input = MemoryFile(mode: .read)
    let output = MemoryFile()
    try externalSort(input: input, numValues: 0, output: output, memSize: MEM_1MiB)
    #expect(output.size == 0)
}

@Test func oneValue() throws {
    let inputValue: UInt64 = 0xabab_42f0_0f00
    let input = MemoryFile(contents: bytes(from: [inputValue]))
    let output = MemoryFile()

    try externalSort(input: input, numValues: 1, output: output, memSize: MEM_1MiB)

    #expect(output.size == 8)
    #expect(values(from: output) == [inputValue])
}

@Test func smallNoPartialRun() throws {
    let inputValues: [UInt64] = [10, 5, 7, 9, 11, 12, 3, 8, 1, 4, 6, 2]
    let input = MemoryFile(contents: bytes(from: inputValues))
    let output = MemoryFile()

    try externalSort(input: input, numValues: 12, output: output, memSize: 24)

    #expect(output.size == 8 * 12)
    #expect(values(from: output) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12])
}

@Test func smallPartialLastRun() throws {
    let inputValues: [UInt64] = [10, 5, 2, 9, 3, 8, 1, 4, 6, 7]
    let input = MemoryFile(contents: bytes(from: inputValues))
    let output = MemoryFile()

    try externalSort(input: input, numValues: 10, output: output, memSize: 24)

    #expect(output.size == 8 * 10)
    #expect(values(from: output) == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
}

// MARK: - Parametrized

private let parametrizedCases: [(memSize: Int, numValues: Int)] = [
    // All values fit in memory:
    (MEM_1KiB, 3),
    (MEM_1KiB, 40),
    (MEM_1KiB, 128),
    (MEM_1MiB, 100_000),
    // n-way merge required:
    (MEM_1KiB, 129),
    (MEM_1KiB, 997),
    (MEM_1KiB, 1024),
    (MEM_1MiB, 200_000),
]

private let advancedCases: [(memSize: Int, numValues: Int)] = [
    // The number of runs after the initial pass exceeds what fits in memory,
    // so multiple merge passes through the temporary file are required.
    (MEM_1KiB, 128 * MEM_1KiB + 1),
    (MEM_1KiB, MEM_1MiB),
]

private let allCases: [(memSize: Int, numValues: Int)] = parametrizedCases + advancedCases

@Test(arguments: allCases)
func sortDescendingNumbers(memSize: Int, numValues: Int) throws {
    var fileValues = [UInt64](repeating: 0, count: numValues)
    var expected = [UInt64](repeating: 0, count: numValues)
    for i in 0..<numValues {
        expected[i] = UInt64(i + 1)
        fileValues[i] = UInt64(numValues - i)
    }
    let input = MemoryFile(contents: bytes(from: fileValues))
    let output = MemoryFile()

    try externalSort(input: input, numValues: numValues, output: output, memSize: memSize)

    #expect(output.size == numValues * 8)
    #expect(values(from: output) == expected)
}

@Test(arguments: allCases)
func sortRandomNumbers(memSize: Int, numValues: Int) throws {
    var (expected, input) = makeRandomNumbers(count: numValues)
    expected.sort()
    let output = MemoryFile()

    try externalSort(input: input, numValues: numValues, output: output, memSize: memSize)

    #expect(output.size == numValues * 8)
    #expect(values(from: output) == expected)
}

@Test(arguments: allCases)
func sortEqualNumbers(memSize: Int, numValues: Int) throws {
    let value: UInt64 = 0xabab_42f0_0f00
    let expected = [UInt64](repeating: value, count: numValues)
    let input = MemoryFile(contents: bytes(from: expected))
    let output = MemoryFile()

    try externalSort(input: input, numValues: numValues, output: output, memSize: memSize)

    #expect(output.size == numValues * 8)
    #expect(values(from: output) == expected)
}

// MARK: - Generic byte-stride API

/// Pack a fixed-size record: 8-byte sort key prefix followed by `padBytes`
/// of payload. Used to exercise the generic externalSort path with rows
/// wider than the UInt64 specialization.
private func packRecords(keys: [UInt64], padBytes: Int) -> [UInt8] {
    let stride = 8 + padBytes
    var out = [UInt8](repeating: 0, count: keys.count * stride)
    out.withUnsafeMutableBytes { dst in
        guard let base = dst.baseAddress else { return }
        for (i, k) in keys.enumerated() {
            // Sort key.
            var key = k
            withUnsafeBytes(of: &key) { src in
                base.advanced(by: i * stride).copyMemory(from: src.baseAddress!, byteCount: 8)
            }
            // Payload — derived from the key so we can verify records weren't
            // shuffled apart from their keys.
            var tag = k &* 0x9E37_79B9_7F4A_7C15
            for off in stride - padBytes..<stride - padBytes + min(padBytes, 8) {
                base.advanced(by: i * stride + off).storeBytes(
                    of: UInt8(tag & 0xff), as: UInt8.self
                )
                tag >>= 8
            }
        }
    }
    return out
}

private func unpackKeys(from file: MemoryFile, stride: Int) -> [UInt64] {
    let count = file.contents.count / stride
    var out = [UInt64](repeating: 0, count: count)
    file.contents.withUnsafeBytes { src in
        guard let base = src.baseAddress else { return }
        for i in 0..<count {
            out[i] = base.loadUnaligned(fromByteOffset: i * stride, as: UInt64.self)
        }
    }
    return out
}

@Test func genericRowSortInMemory() throws {
    let stride = 34  // 8-byte key + 26-byte payload (≈ two registers' worth)
    let keys: [UInt64] = [10, 5, 7, 9, 11, 12, 3, 8, 1, 4, 6, 2]
    let input = MemoryFile(contents: packRecords(keys: keys, padBytes: stride - 8))
    let output = MemoryFile()

    try externalSort(
        input: input,
        numElements: keys.count,
        elementSize: stride,
        output: output,
        memSize: MEM_1KiB
    ) { a, b in
        a.loadUnaligned(as: UInt64.self) < b.loadUnaligned(as: UInt64.self)
    }

    #expect(output.size == keys.count * stride)
    #expect(unpackKeys(from: output, stride: stride) == keys.sorted())
}

@Test func genericRowSortRequiresMerge() throws {
    let stride = 170  // 10 registers' worth — wide row
    let keyCount = 5000
    var keys = [UInt64]()
    keys.reserveCapacity(keyCount)
    var rng = SeededGenerator(seed: 42)
    for _ in 0..<keyCount {
        keys.append(UInt64.random(in: .min ... .max, using: &rng))
    }
    let input = MemoryFile(contents: packRecords(keys: keys, padBytes: stride - 8))
    let output = MemoryFile()

    // Pick a memSize that forces multiple merge passes for `stride`-sized
    // records.
    let memSize = stride * 32

    try externalSort(
        input: input,
        numElements: keyCount,
        elementSize: stride,
        output: output,
        memSize: memSize
    ) { a, b in
        a.loadUnaligned(as: UInt64.self) < b.loadUnaligned(as: UInt64.self)
    }

    #expect(output.size == keyCount * stride)
    #expect(unpackKeys(from: output, stride: stride) == keys.sorted())

    // Verify each record's payload still matches its key (i.e. records moved
    // as whole units, not just keys).
    let expected = packRecords(keys: keys.sorted(), padBytes: stride - 8)
    #expect(output.contents == expected)
}
