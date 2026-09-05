# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Swift implementation of the core storage and execution layers of a relational database engine — buffer manager, slotted pages, B+-tree, external sort, the iterator-model operators, and a SQL front-end (`sql`). The goal is implementations that are simultaneously **fast and ergonomic**.

The product lives in `Sources/Database/` (pure Swift), with the interactive CLI in `Sources/SQL/`. Tests are under `Tests/DatabaseTests/` and use the `Testing` framework (`@Test`, `#expect`) — not XCTest.

swift-tools 6.2. macOS 13+, Apple Silicon. No external native dependencies.

## Design discipline

- **Speed and usability are co-primary.** If a "fast" design forces every caller into unsafe pointers or manual lifetime management, it's failing the usability half. If a "clean" design boxes everything and copies on every access, it's failing the speed half. Call out the tradeoff when it's load-bearing.
- **Preserve the contracts encoded by the test suite.** The contracts below (page-id layout, TID-redirect bound of one, k-way merge memory budget, iterator-model semantics, etc.) are load-bearing — don't relax them when refactoring.
- Prefer Swift-native idioms — value types where they fit, `actor`/`async` for concurrency, `Sendable` correctness — over patterns transliterated from other languages.

## Per-component spec

| Component | Path | Key contracts |
|---|---|---|
| Storage primitives | `Sources/Database/Storage` | The layer under the buffer manager: `File`/`PosixFile` for I/O, `Mutex` and `RWLock` for latching. Platform imports are conditional (`Darwin` / `Glibc` / `Musl`) — keep all three arms when adding one. |
| Buffer manager | `Sources/Database/BufferManager` | 2Q replacement; 64-bit page id = 16-bit segment id (high) ∥ 48-bit page id (low); files named after segment id; latches must not be held across disk I/O; thread-safe `fix`/`unfix` from multiple threads. |
| Slotted pages | `Sources/Database/SlottedPages` | Slotted pages on top of the buffer manager; free-space inventory (may span multiple pages); TID redirects bounded to **one** hop (don't chain). |
| B+-Tree | `Sources/Database/BTree` | `insert` / `erase` / `lookup`; page-id-based child references; latch coupling for concurrency; leaf-link is optional. The tree is byte-keyed: it stores `keyStride` raw bytes and orders them with the `less` closure given to its initializer. `BTreeKeys.swift` packages the three flavours in use — `Int64`, `UInt64`, and char (lexicographic over the column width, NUL-filled, matching `Register`). Backs the secondary indexes. |
| External sort | `Sources/Database/ExternalSort` | Generic k-way external merge sort over fixed-stride records (runtime `elementSize` + a `compare` closure); a `UInt64` convenience overload wraps it. Memory-size argument is a **hard heap-byte cap**, not a hint. Reused by the `Sort` operator via `SortSpillover`. |
| Operators | `Sources/Database/Operators` | Iterator model; register-pointer exchange happens **once during `open()`**, `next()` mutates behind the same pointers; `Register` holds `Int64` or fixed-16 string. `IndexScan` emits TIDs; `TIDResolve` turns a TID stream into full rows (same shape as `TableScan`). Set ops: `Union`/`UnionAll`/`Intersect`/`IntersectAll`/`Except`/`ExceptAll`. |
| Indexes | `Sources/Database/SlottedPages/DatabaseIndex.swift` + `Schema.swift` | Single-column **unique** secondary indexes (`SchemaIndex`), `BTree`-backed, value = `TID.rawValue`. A single-column PRIMARY KEY is auto-indexed; `CREATE INDEX` adds more. Index BTree headers persist in the schema JSON so reopen finds the real root. |
| SQL / CLI | `Sources/Database/SQL` + `Sources/SQL` | Lexer → Parser → SemanticAnalysis → Planner → operator tree → `Print`. SELECT (with `UNION`/`INTERSECT`/`EXCEPT` `[ALL]`, chained or parenthesised; INTERSECT binds tightest), CREATE TABLE, CREATE INDEX, DROP TABLE, INSERT, COPY FROM CSV. Planner emits `IndexScan`+`TIDResolve` for an equality on an indexed column, else `TableScan`. |

## Build / test

CI (`.github/workflows/ci.yml`, macos-15) runs exactly these three, in this order, and stops at the
first failure:

```sh
swift format lint --strict --recursive Sources Tests Package.swift
swift build --build-tests
swift test --no-parallel
```

Also useful locally:

```sh
swift test --no-parallel --filter someTest  # single test (matches by name)
swift build -c release                      # benchmark builds
```

`--no-parallel` is mandatory, not a fallback: the test harness uses a process-global `chdir` to
place segment files (`Tests/DatabaseTests/TestSupport.swift`), so suites corrupt each other's files
when run concurrently. `--build-tests` is what makes the build step catch a broken test target
rather than leaving it for the test step. `--strict` promotes every lint warning to an error, and
`.swift-format` sets 4-space indentation, a 120-column line length and at most one consecutive
blank line.
