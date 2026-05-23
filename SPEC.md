# zql Specification

## 1. Purpose and positioning

zql is a small, zero-dependency SQL string builder for Zig. It assembles
structurally correct SQL strings from plain Zig config structs and raw SQL
fragments. It is not an ORM, not a database driver, and not a SQL-injection
safety layer.

## 2. Target users and use cases

zql targets Zig applications that already use a database driver and want
lightweight help building SQL strings, especially for optional filters,
pagination, ordering, CRUD statements, simple DDL, aggregate expressions,
and composed WHERE fragments.

Raw SQL remains preferred for fixed, static queries. zql is most useful when
the query shape is conditional or assembled from reusable fragments.

## 3. API surface

### Statements

Every statement has two entry points:

- **Allocator API** — returns a caller-owned `[]u8`
- **Writer API** — writes directly to `std.Io.Writer`, zero intermediate allocations

| Statement | Config | Writer |
|---|---|---|
| SELECT | `select` | `writeSelect` |
| INSERT | `insert` | `writeInsert` |
| INSERT MANY | `insertMany` | `writeInsertMany` |
| UPDATE | `update` | `writeUpdate` |
| DELETE | `delete` | `writeDelete` |
| CREATE TABLE | `createTable` | `writeCreateTable` |
| DROP TABLE | `dropTable` | `writeDropTable` |
| CREATE INDEX | `createIndex` | `writeCreateIndex` |

### Helpers

Where fragment builders. Each returns a caller-owned `[]u8`.

| Helper | Output example |
|---|---|
| `eq(col, value)` | `col = value` |
| `ne(col, value)` | `col <> value` |
| `gt(col, value)` | `col > value` |
| `lt(col, value)` | `col < value` |
| `ge(col, value)` | `col >= value` |
| `le(col, value)` | `col <= value` |
| `all(conditions)` | `a AND b AND c` |
| `any(conditions)` | `a OR b OR c` |
| `group(condition)` | `(condition)` |
| `not(condition)` | `NOT (condition)` |
| `in(col, values)` | `col IN (v1, v2, v3)` |
| `notIn(col, values)` | `col NOT IN (v1, v2, v3)` |
| `between(col, low, high)` | `col BETWEEN low AND high` |
| `betweenDates(col, from, to)` | `col BETWEEN from AND to` |
| `isNull(col)` | `col IS NULL` |
| `isNotNull(col)` | `col IS NOT NULL` |
| `like(col, pattern)` | `col LIKE pattern` |

### Aggregate and scalar functions

Two variants per function: bare and aliased (`*As`).

| Bare | Aliased |
|---|---|
| `sum(col)` | `sumAs(col, alias)` |
| `count(col)` | `countAs(col, alias)` |
| `countDistinct(col)` | `countDistinctAs(col, alias)` |
| `avg(col)` | `avgAs(col, alias)` |
| `min(col)` | `minAs(col, alias)` |
| `max(col)` | `maxAs(col, alias)` |
| `coalesce(col, fallback)` | `coalesceAs(col, fallback, alias)` |
| `cast(col, as_type)` | `castAs(col, as_type, alias)` |

### Shared types

```zig
pub const Direction = enum { asc, desc };

pub const Order = struct {
    col: []const u8,
    dir: Direction = .asc,
};

pub const Column = struct {
    name:        []const u8,
    type:        []const u8,
    constraints: []const u8 = "",
};

pub const Error = error{
    ColsValuesMismatch,
    NoColumns,
    NoIndexName,
    NoRows,
    NoSetClauses,
    NoTable,
    NoValues,
};
```

## 4. API principles

- Configuration is expressed with plain structs, slices, optionals, enums, and
caller-provided allocators.
- `null` in a config field means "omit this clause."
- Every allocated result is caller-owned and must be freed with the allocator
that produced it.
- Every statement-level allocator function has a paired writer function that
writes to `std.Io.Writer`.

## 5. Safety boundaries

zql emits SQL text exactly from the identifiers, fragments, and values supplied
by the caller. It does not escape, sanitize, or bind user input.

- **Trusted program values** (constants, enums, validated state) may be inlined
  directly via helpers.
- **Untrusted input** (request parameters, user text, external data) must be
  represented by driver placeholders and bound separately by the database driver.

Helpers that inline literal values (`betweenDates`, `like`, `eq`, etc.) are
documented as "trusted literals only." The caller is responsible for ensuring
inlined values are safe.

## 6. Correctness expectations

zql guarantees structural SQL ordering:

```
SELECT → FROM → JOIN → WHERE → GROUP BY → HAVING → ORDER BY → LIMIT → OFFSET
```

Modeled statements return explicit validation errors for missing required fields:

| Error | Trigger |
|---|---|
| `NoTable` | Empty table name on any statement |
| `NoColumns` | Empty column list on INSERT, CREATE TABLE, CREATE INDEX |
| `NoValues` | Empty values on INSERT |
| `NoSetClauses` | Empty set list on UPDATE |
| `NoIndexName` | Empty index name on CREATE INDEX |
| `NoRows` | Empty rows on INSERT MANY |
| `ColsValuesMismatch` | Column/value count mismatch on INSERT / INSERT MANY |

## 7. Memory and performance contract

Statement-level allocator functions render with exactly one final allocation
sized to the output, using the paired writer implementation as the source of
truth. Writer functions stream directly to the supplied writer and do not
allocate.

Small fragment helpers allocate when their return type is an owned `[]u8`.
Their ownership and allocation behavior is documented.

## 8. Documentation requirements

The README must:

- Present zql as a dynamic SQL string builder.
- Explain when raw SQL is preferable.
- Show production-safe placeholder-based examples.
- Reference the actual repository and current release tag in installation
  instructions.
- Include a concrete side-by-side comparison of dynamic SQL with and without
  zql.

## 9. Quality bar

- `zig build test` passes on the supported Zig version.
- Inline tests exist for every modeled statement and helper.
- Regression tests exist for every validation error.
- The package remains dependency-free at the library level.
- Optional examples have isolated dependencies that do not leak into downstream
  users.
