# Database

A small but real relational database engine, written from scratch in Swift. It implements the layers that sit underneath a SQL prompt — how bytes are laid out on disk, how pages are cached in memory, how rows and indexes are stored, how a query is turned into a plan and executed — and exposes them through an interactive `sql` shell.

It is built for **learning**. If you have used SQL but never seen what happens after you press enter, this codebase walks you down through every layer, with each layer small enough to read in one sitting.

> **Inspiration.** The design follows the concepts taught in *Database Systems on Modern CPU Architectures* and *Query Optimization* at TU München (TUM): a buffer manager with a 2Q replacement policy, slotted pages with a free-space inventory, a B+-tree, external (on-disk) sorting, and the iterator/Volcano execution model. This is an independent Swift implementation of those ideas.

---

## Quick start

Requirements: Swift 6.2+, macOS 13+ (Apple Silicon).

```sh
swift build            # build the library + the `sql` CLI
swift test             # run the test suite (132 tests)
swift run sql mydb     # open (or create) a database in ./mydb and start a REPL
```

A "database" is just a directory of files. Point the CLI at any path; it is created on first use.

```
$ swift run sql mydb
sql> CREATE TABLE users (id INTEGER, name CHAR(16), PRIMARY KEY (id));
CREATE TABLE
sql> INSERT INTO users VALUES (1, 'alice');
INSERT 1
sql> INSERT INTO users VALUES (2, 'bob');
INSERT 1
sql> SELECT id, name FROM users WHERE id = 1;
1,alice
sql> exit
```

Other ways to run it:

```sh
swift run sql mydb -c "SELECT * FROM users"   # run one statement and exit
swift run sql mydb -f script.sql              # run a file of ;-separated statements
swift run sql mydb --open-only                # fail if the database doesn't already exist
```

---

## Documentation

API reference for every public type is published with [DocC](https://www.swift.org/documentation/docc/) to GitHub Pages:

**https://pauljohanneskraft.github.io/Database/documentation/database/**

The landing page lists every public symbol grouped by kind, and each type links down to its members — so the whole API is reachable by clicking, no URL-guessing. The docs are rebuilt and redeployed on every push to `main`.

---

## How the layers fit together

A query falls through these layers from top to bottom. Each is a directory under `Sources/Database/`.

| Layer | Where | What it does |
|---|---|---|
| **Storage** | `Storage/` | Raw file I/O. `File` is the protocol; `PosixFile` is the `pread`/`pwrite` implementation. `Mutex` / `RWLock` are the locking primitives the upper layers latch with. |
| **Buffer manager** | `BufferManager/` | Caches fixed-size pages in memory so the engine isn't doing a disk read per row. `BufferManager` hands out `BufferFrame`s via `fix`/`unfix`, evicts cold pages with a 2Q policy, and is safe to call from many threads. A 64-bit page id is `16-bit segment id ∥ 48-bit page id`. |
| **Slotted pages** | `SlottedPages/` | Turns opaque pages into variable-length records. `SlottedPage` is the on-page layout; `SPSegment` stores/fetches/updates/deletes records addressed by `TID` (tuple id); `FSISegment` is the free-space inventory that finds a page with room. |
| **B+-tree** | `BTree/` | The index structure. `BTree` supports `insert`/`lookup`/`erase` with latch coupling for concurrency; `Char16` is the 16-byte key type used for `CHAR` columns. |
| **Operators** | `Operators/` | Query execution, "iterator model": every operator answers `open()` / `next()` / `close()` and pulls rows from its children one at a time. Values flow through shared `Register`s. |
| **SQL front-end** | `SQL/` | `Lexer` → `Parser` → `SemanticAnalysis` → `Planner` produce the operator tree; `SQLExecutor` is the one entry point the CLI and tests both call. |
| **CLI** | `Sources/SQL/` | `main.swift` — the `sql` REPL / script runner that wraps `SQLExecutor`. |

The whole engine is the `Database` library target; the `sql` executable is a thin shell on top of it.

---

## What you can do from the `sql` shell

Everything below is reachable through the CLI. Each feature links to the types that implement it, so you can read the SQL command and then jump straight to the code behind it.

### Create a database
Just open a directory — there is no separate "init" step.

- **Behind it:** `Database.create` / `Database.open` (`SlottedPages/Database.swift`) lay out and load the segment files; `SchemaSegment` persists the catalog (your tables and indexes) as JSON so it survives a reopen.

### `CREATE TABLE`
```sql
CREATE TABLE users (id INTEGER, name CHAR(16), PRIMARY KEY (id));
```
Columns are typed `INTEGER` or `CHAR(n)`. A single-column `PRIMARY KEY` is automatically given a unique index.

- **Behind it:** parsed into `CreateTableAST` (`SQL/Statement.swift`); the column types are `SchemaType` (`SlottedPages/Schema.swift`); the table is registered in `Schema` and gets its own `SPSegment` for row storage. A single-column PK auto-creates a `BTree`-backed index.

### `CREATE INDEX`
```sql
CREATE INDEX users_by_name ON users (name);
```
Adds a **unique** secondary index on one column.

- **Behind it:** `CreateIndexAST` → `Database.createIndex`; the index is a `SchemaIndex` (`SlottedPages/DatabaseIndex.swift`) wrapping a `BTree` whose values are `TID`s pointing back at the row. The index's tree root is recorded in the schema JSON so a reopened database finds it again.

### `INSERT`
```sql
INSERT INTO users VALUES (1, 'alice');
```

- **Behind it:** `InsertAST` → `Database.insert`. The row is placed on a page chosen by the `FSISegment` free-space lookup, stored by `SPSegment` as a record addressed by a new `TID`, and any indexes on the table are updated.

### `COPY … FROM` (bulk CSV load)
```sql
COPY users FROM 'people.csv' CSV HEADER;
```

- **Behind it:** `CopyAST` → `CSVLoader` (`SQL/CSVLoader.swift`), which streams the file and inserts each line through the same `SPSegment` path as `INSERT`. Returns `COPY <n>`.

### `SELECT` with `WHERE` filters and joins
```sql
SELECT name FROM users WHERE id = 1;
SELECT u.name, o.total FROM users u, orders o WHERE u.id = o.user_id AND o.total = 100;
```
List one or more tables in `FROM`; `WHERE` predicates are equalities (`=`) joined by `AND`. An `attr = constant` is a **filter**; an `attr = attr` across two tables is an **equi-join**. `SELECT *` projects everything.

- **Behind it:** `SemanticAnalysis` (`SQL/SemanticAnalysis.swift`) resolves names/types against the `Schema`; `Planner` (`SQL/Planner.swift`) lowers it to an operator tree:
  - leaf scans are `TableScan`, or `IndexScan` + `TIDResolve` when a filter hits an indexed column (see below),
  - `attr = attr` predicates become `HashJoin` (or `CrossProduct` when no join condition connects two tables),
  - `attr = constant` predicates become `Select`,
  - the column list becomes `Projection`,
  - `Print` renders the rows the CLI prints.

### Automatic index use
If you filter on an indexed column with equality, the planner uses the index instead of scanning the whole table — no special syntax needed.

- **Behind it:** in `Planner.makeScan`, an equality on an indexed column is turned into an `IndexScan` (which emits matching `TID`s) feeding a `TIDResolve` (which fetches the full rows) — same row shape as a `TableScan`, so the rest of the plan doesn't care which was used. Otherwise it falls back to a full `TableScan`.

### Set operations
```sql
SELECT id FROM a UNION SELECT id FROM b;
SELECT id FROM a INTERSECT ALL SELECT id FROM b;
SELECT id FROM a EXCEPT SELECT id FROM b;
```
`UNION`, `INTERSECT`, and `EXCEPT`, each with an optional `ALL` (bag vs. set semantics). They chain and can be parenthesised; per the SQL standard, `INTERSECT` binds tightest.

- **Behind it:** the parser builds a `SelectExpr` tree (`SQL/QueryAST.swift`); the `Planner` maps each node to the matching operator: `Union` / `UnionAll` / `Intersect` / `IntersectAll` / `Except` / `ExceptAll` (`Operators/Operators.swift`).

### `DROP TABLE`
```sql
DROP TABLE users;
```

- **Behind it:** removes the table and its indexes from the `Schema` and re-persists the catalog via `Database.persistSchema`.

> **Engine vs. SQL surface.** The execution engine also includes `Sort` (backed by the on-disk `ExternalSort` + `SortSpillover`) and `HashAggregation` operators. These are fully implemented and tested at the operator level, but the SQL grammar above does not yet expose `ORDER BY` / `GROUP BY` — a good first feature to add if you want to extend the front-end.

---

## Project layout

```
Sources/
  Database/              the engine (library target)
    Storage/             file I/O + locking primitives
    BufferManager/       page cache, 2Q eviction, segment/page-id scheme
    SlottedPages/        records, free-space inventory, schema/catalog, on-disk Database
    BTree/               B+-tree index + Char16 key
    Operators/           iterator-model query operators + Register exchange
    ExternalSort/        generic k-way on-disk merge sort
    SQL/                 lexer, parser, semantic analysis, planner, executor, CSV loader
  SQL/                   the `sql` command-line shell (executable target)
Tests/
  DatabaseTests/         132 tests (uses the swift-testing framework: @Test / #expect)
```

## Tests

```sh
swift test                      # everything
swift test --filter SQLSuite    # one suite, matched by name
swift test --no-parallel        # serial run, if you suspect a concurrency issue
```

The tests are written with Swift's `Testing` framework (`@Test`, `#expect`), not XCTest, and double as runnable documentation: each layer's expected contracts (page-id layout, one-hop TID redirects, the external-sort memory cap, iterator semantics) are pinned down by a test you can read.
