# ``Database``

A small but real relational database engine — the layers beneath a SQL prompt, written from scratch in Swift.

## Overview

`Database` implements the storage and execution machinery a SQL engine sits on
top of, and exposes it as ordinary Swift API. A query falls through the layers
top to bottom: the **SQL front-end** turns text into a plan, the **query
operators** execute that plan in the iterator (Volcano) model, and the
**storage stack** — buffer manager, slotted pages, B+-tree, external sort —
keeps bytes on disk and pages in memory.

The Topics below are grouped by layer rather than by Swift kind, so each
subsystem reads as a unit. Start at ``SQLExecutor`` for the end-to-end path, or
``BufferManager`` / ``BTree`` for the storage internals.

## Topics

### SQL Front-End

The text-to-plan pipeline: lexer → parser → semantic analysis → planner, plus
the statement ASTs and the executor that drives a statement to output.

- ``SQLExecutor``
- ``Lexer``
- ``Token``
- ``TokenWithSpan``
- ``Span``
- ``Parser``
- ``Statement``
- ``QueryAST``
- ``SelectExpr``
- ``SetOpKind``
- ``CreateTableAST``
- ``CreateIndexAST``
- ``InsertAST``
- ``CopyAST``
- ``SemanticAnalysis``
- ``BoundQuery``
- ``BoundSelectExpr``
- ``Planner``
- ``CSVLoader``
- ``CSVError``
- ``SQLError``

### Query Operators

The iterator-model operator tree. Register pointers are exchanged once during
`open()`; `next()` mutates behind them.

- ``Operator``
- ``UnaryOperator``
- ``BinaryOperator``
- ``Register``
- ``TableScan``
- ``IndexScan``
- ``TIDResolve``
- ``Select``
- ``Projection``
- ``Sort``
- ``HashAggregation``
- ``HashJoin``
- ``CrossProduct``
- ``Union``
- ``UnionAll``
- ``Intersect``
- ``IntersectAll``
- ``Except``
- ``ExceptAll``
- ``Print``
- ``TextOutput``

### Database & Catalog

The on-disk database and the schema/catalog it persists.

- ``Database``
- ``DatabaseError``
- ``Schema``
- ``SchemaSegment``
- ``SchemaTable``
- ``SchemaColumn``
- ``SchemaType``
- ``SchemaIndex``
- ``AnyIndex``

### Slotted Pages & Records

Variable-length records on top of fixed-size pages, addressed by `TID`.

- ``SlottedPage``
- ``SPSegment``
- ``FSISegment``
- ``TID``
- ``SlottedPageError``
- ``SPSegmentError``

### B+-Tree

The index structure backing primary keys and secondary indexes.

- ``BTree``

### Buffer Manager

Caches fixed-size pages in memory with a 2Q replacement policy.

- ``BufferManager``
- ``BufferFrame``
- ``BufferError``

### External Sort

Generic k-way external merge sort over fixed-stride records, with a hard
heap-byte budget.

- ``externalSort(input:numElements:elementSize:output:memSize:compare:)``
- ``externalSort(input:numValues:output:memSize:)``

### Storage & Primitives

Raw file I/O and the locking primitives the upper layers latch with.

- ``Segment``
- ``File``
- ``PosixFile``
- ``MemoryFile``
- ``FileMode``
- ``FileError``

### Debugging

- ``hexDump(_:width:)-(UnsafeRawBufferPointer,_)``
- ``hexDump(_:width:)-([UInt8],_)``
