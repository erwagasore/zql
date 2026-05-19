# zql

A zero-dependency, database-agnostic SQL query builder for Zig.

- **Pure Zig** — no C bindings, no runtime dependencies
- **Database-agnostic** — works with SQLite, PostgreSQL, rqlite, or any SQL database
- **Idiomatic** — built on `std.Io.Writer`, follows Zig standard library memory conventions
- **Simple** — one function per statement type, plain struct config
- **Zig 0.16+**

## Scope: value binding is your driver's job

zql is a SQL **string builder** — it produces SQL text from typed Zig
configs. It does **not** escape or bind values. Concatenating untrusted
input directly into `.where`, `.values`, `.set`, etc. is a SQL-injection
vulnerability, and preventing it is explicitly **not** zql's responsibility.

In production code, render placeholder SQL with whatever binding syntax
your driver uses (`?` for SQLite/MySQL, `$1` for Postgres) and pass the
user input as separately-bound parameters:

```zig
const sql = try zql.select(a, .{
    .table = "users",
    .where = "email = ?",      // ← placeholder, NOT "email = '" ++ input ++ "'"
});
// Then hand off to your driver:
// try db.exec(sql, .{ user_input_email });
```

zql renders the SQL string; your driver binds the values. This separation
is what keeps zql dialect-neutral — and it's what keeps user input safe.

## Why zql over raw SQL strings

### Compile-time direction safety

Raw SQL lets you write `"ORDER BY name DESK"` — a typo that compiles, runs, and silently
returns wrong results. zql's `Direction` enum makes that impossible:

```zig
// Raw SQL — valid Zig, wrong results at runtime
"ORDER BY name DESK"

// zql — caught at compile time
.order = &.{.{ .col = "name", .dir = .desk }}
// error: no field 'desk' in enum 'Direction'
```

### Typed LIMIT and OFFSET

Format string errors with numeric clauses are easy to make and silent:

```zig
// Raw SQL — {s} expects a string, usize causes a runtime panic or garbage output
const sql = try std.fmt.allocPrint(a, "SELECT * FROM users LIMIT {s}", .{limit});

// zql — limit is typed as ?usize, passing a string is a compile error
.limit = limit,  // correct
.limit = "50",   // compile error
```

### Correct clause ordering guaranteed

SQL requires a strict clause order: `WHERE` before `GROUP BY`, `GROUP BY` before `HAVING`,
`HAVING` before `ORDER BY`. Raw SQL lets you get this wrong silently. zql always emits
clauses in the correct order regardless of the order you specify them in the config struct:

```zig
// Raw SQL — valid Zig, invalid SQL, silent runtime failure
"SELECT * FROM users GROUP BY country WHERE active = 1"

// zql — WHERE always emitted before GROUP BY, always correct
.where = "active = 1",
.group = &.{"country"},
```

### Conditional clauses without string surgery

Dynamically building a query in raw SQL means `ArrayList`, careful spacing, and
concatenation bugs. In zql optional fields are just `null`:

```zig
// zql — clean, correct, readable
const sql = try zql.select(a, .{
    .table  = "users",
    .where  = if (filter_active) "active = 1" else null,
    .limit  = if (paginated) page_size else null,
    .offset = if (paginated) page * page_size else null,
});
```

The raw SQL equivalent requires building the string piece by piece with an `ArrayList`
and careful attention to spacing between clauses.

### Composable WHERE without concatenation

```zig
// Conditionally add filters
var conditions: std.ArrayList([]const u8) = .empty;
defer conditions.deinit(a);            // no-op with arena, required with GPA
try conditions.append(a, "active = 1");
if (jurisdiction) |j| {
    try conditions.append(a, try std.fmt.allocPrint(a, "jurisdiction = '{s}'", .{j}));
}

const sql = try zql.select(a, .{
    .table = "users",
    .where = try zql.all(a, conditions.items),
});
```

### Refactoring safety

Column names in `.cols`, `.group`, and `.order` are struct fields — visible in diffs,
easy to grep, and can be centralised as constants:

```zig
const USER_COLS = &.{ "id", "name", "email" };

// Every query that selects users updated in one place
const sql = try zql.select(a, .{
    .table = "users",
    .cols  = USER_COLS,
});
```

### When to use raw SQL instead

zql covers the common 80% — CRUD, pagination, filters, aggregates, joins. For the
remaining 20%, every `[]const u8` field accepts raw SQL directly:

```zig
.having = "SUM(total) > (SELECT AVG(total) FROM orders)",
```

See [Dialect-specific features](#dialect-specific-features-use-raw-sql) for
a catalogue of common features intentionally not modeled (upserts, RETURNING,
CTEs, window functions, UNION, ALTER TABLE, quoted identifiers, …) with
ready-to-paste recipes for each.

---

## Memory contract

Every function that returns a `[]u8` performs **exactly one allocation**,
sized precisely to the output — no grow-reallocs during construction, no
shrink-to-fit at the end, no transient buffers. This matters most for arena
allocators, where intermediate reallocs would otherwise stay resident until
`arena.deinit()`.

The caller owns the result and must free it with the same allocator.

```zig
// GPA — explicit defer
const sql = try zql.select(allocator, .{ .table = "users" });
defer allocator.free(sql);
```

```zig
// httpz handler — req.arena frees everything at end of request, no defer needed
const sql = try zql.select(req.arena, .{ .table = "users", .limit = 50 });
```

```zig
// Arena — one deinit frees all intermediate and final allocations
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const a = arena.allocator();

const sql = try zql.select(a, .{
    .table = "users",
    .cols  = &.{ try zql.sumAs(a, "amount", "total"), "user_id" },
    .where = try zql.all(a, &.{
        "active = 1",
        try zql.betweenDates(a, "created_at", "2026-01-01", "2026-04-01"),
    }),
    .group = &.{"user_id"},
});
```

```zig
// Fixed buffer — no heap, no free
var buf: [512]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&buf);
const sql = try zql.select(fba.allocator(), .{ .table = "users", .where = "active = 1" });
```

---

## Writer API (zero intermediate allocations)

Every statement has a paired `writeX` variant that writes directly to any
`std.Io.Writer`. Use it when you already have a writer (file, socket,
in-memory buffer) and want to skip the intermediate allocation:

```zig
// Write SQL straight into a fixed buffer
var buf: [256]u8 = undefined;
var w: std.Io.Writer = .fixed(&buf);
try zql.writeSelect(&w, .{ .table = "users", .where = "active = 1" });
// w.buffered() → "SELECT * FROM users WHERE active = 1"
```

Available pairs: `select`/`writeSelect`, `insert`/`writeInsert`,
`insertMany`/`writeInsertMany`, `update`/`writeUpdate`, `delete`/`writeDelete`,
`createTable`/`writeCreateTable`, `dropTable`/`writeDropTable`,
`createIndex`/`writeCreateIndex`. The allocator forms are thin convenience
wrappers around the writer forms.

---

## Errors

`zql.Error` is the union of every validation error any function may return:

```zig
pub const Error = error{
    ColsValuesMismatch, // insert: cols.len != values.len; insertMany: row mismatch
    NoRows,             // insertMany: rows is empty
    NoSetClauses,       // update: set is empty
    NoColumns,          // createTable / createIndex: cols is empty
};
```

Each `writeX` function declares the precise subset it can return — read its
signature to see which apply. For a catch-all in caller code:

```zig
fn handler(req: *Request) (zql.Error || std.Io.Writer.Error || Allocator.Error)!Response {
    const sql = try zql.insert(req.arena, .{ ... });
    ...
}
```

---

## Types

Shared value types used across the API:

```zig
/// Sort direction for ORDER BY terms.
pub const Direction = enum { asc, desc };

/// A single ORDER BY term. Used in SelectConfig.order.
pub const Order = struct {
    col: []const u8,
    dir: Direction = .asc,
};

/// Column definition for CREATE TABLE. Used in CreateTableConfig.cols.
pub const Column = struct {
    name:        []const u8,
    type:        []const u8,
    constraints: []const u8 = "",
};
```

Every statement also has its own config struct — `SelectConfig`,
`InsertConfig`, `InsertManyConfig`, `UpdateConfig`, `DeleteConfig`,
`CreateTableConfig`, `DropTableConfig`, `CreateIndexConfig`. Field names
and defaults appear in the [Usage](#usage) examples below, and the full
definitions live in [`src/zql.zig`](src/zql.zig).

---

## Extending: custom statement types

The single-allocation renderer is public. Pair a config struct with a writer
function, then call `zql.renderOwned`:

```zig
pub const TruncateConfig = struct { table: []const u8 = "" };

pub fn writeTruncate(w: *std.Io.Writer, cfg: TruncateConfig) std.Io.Writer.Error!void {
    try w.print("TRUNCATE TABLE {s}", .{cfg.table});
}

pub fn truncate(gpa: Allocator, cfg: TruncateConfig) ![]u8 {
    return zql.renderOwned(gpa, cfg, writeTruncate);
}
```

You get the same one-allocation-per-call memory profile as the built-in
statements, for free.

---

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .zql = .{
        .url  = "https://github.com/yourname/zql/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Add to your `build.zig`:

```zig
const zql_dep = b.dependency("zql", .{});
exe.root_module.addImport("zql", zql_dep.module("zql"));
```

---

## Usage

### SELECT

```zig
// SELECT * FROM users
const sql = try zql.select(allocator, .{
    .table = "users",
});

// SELECT id, name, email FROM users WHERE active = 1 ORDER BY name ASC LIMIT 50
const sql = try zql.select(allocator, .{
    .table  = "users",
    .cols   = &.{ "id", "name", "email" },
    .where  = "active = 1",
    .order  = &.{.{ .col = "name", .dir = .asc }},
    .limit  = 50,
    .offset = 0,
});

// SELECT DISTINCT country FROM users
const sql = try zql.select(allocator, .{
    .table    = "users",
    .cols     = &.{"country"},
    .distinct = true,
});

// SELECT users.id, orders.total FROM users
// INNER JOIN orders ON orders.user_id = users.id
// WHERE users.active = 1
const sql = try zql.select(allocator, .{
    .table = "users",
    .cols  = &.{ "users.id", "orders.total" },
    .joins = &.{"INNER JOIN orders ON orders.user_id = users.id"},
    .where = "users.active = 1",
});

// SELECT user_id, COUNT(*) AS total FROM orders
// GROUP BY user_id HAVING COUNT(*) > 5
const sql = try zql.select(allocator, .{
    .table  = "orders",
    .cols   = &.{ "user_id", try zql.countAs(allocator, "*", "total") },
    .group  = &.{"user_id"},
    .having = "COUNT(*) > 5",
});
```

### INSERT

```zig
// INSERT INTO users (name, email) VALUES ('Eugene', 'eugene@pindo.io')
const sql = try zql.insert(allocator, .{
    .table  = "users",
    .cols   = &.{ "name", "email" },
    .values = &.{ "'Eugene'", "'eugene@pindo.io'" },
});

// Multi-row insert
const sql = try zql.insertMany(allocator, .{
    .table = "users",
    .cols  = &.{ "name", "email" },
    .rows  = &.{
        &.{ "'Eugene'", "'eugene@pindo.io'" },
        &.{ "'Alice'",  "'alice@example.com'" },
    },
});
```

> Dialect-specific upserts (SQLite `INSERT OR REPLACE` / `INSERT OR IGNORE`,
> Postgres `ON CONFLICT`, MySQL `INSERT IGNORE`) are not modeled by zql — they
> would force one dialect's syntax on every user. Write those statements as
> raw SQL; see [When to use raw SQL instead](#when-to-use-raw-sql-instead).

### UPDATE

```zig
// UPDATE users SET name = 'Eugene', active = 1 WHERE id = 1
const sql = try zql.update(allocator, .{
    .table = "users",
    .set   = &.{ "name = 'Eugene'", "active = 1" },
    .where = "id = 1",
});
```

### DELETE

```zig
// DELETE FROM users WHERE id = 1
const sql = try zql.delete(allocator, .{
    .table = "users",
    .where = "id = 1",
});

// DELETE FROM users (all rows)
const sql = try zql.delete(allocator, .{
    .table = "users",
});
```

### CREATE TABLE

```zig
const sql = try zql.createTable(allocator, .{
    .table         = "users",
    .if_not_exists = true,
    .cols          = &.{
        .{ .name = "id",    .type = "INTEGER", .constraints = "PRIMARY KEY AUTOINCREMENT" },
        .{ .name = "name",  .type = "TEXT",    .constraints = "NOT NULL" },
        .{ .name = "email", .type = "TEXT",    .constraints = "NOT NULL UNIQUE" },
    },
});
```

### DROP TABLE

```zig
const sql = try zql.dropTable(allocator, .{
    .table     = "users",
    .if_exists = true,
});
```

### CREATE INDEX

```zig
const sql = try zql.createIndex(allocator, .{
    .name          = "idx_users_email",
    .table         = "users",
    .cols          = &.{"email"},
    .unique        = true,
    .if_not_exists = true,
});
```

### WHERE helpers

All return caller-owned slices. Compose freely — each helper is just a string.

```zig
// AND
const w = try zql.all(allocator, &.{ "active = 1", "age > 18" });
// → "active = 1 AND age > 18"

// OR
const w = try zql.any(allocator, &.{ "role = 'admin'", "role = 'mod'" });
// → "role = 'admin' OR role = 'mod'"

// Grouping
const w = try zql.group(allocator, "a = 1 OR b = 2");
// → "(a = 1 OR b = 2)"

// NOT
const w = try zql.not(allocator, "active = 1");
// → "NOT (active = 1)"

// IN / NOT IN — values are emitted verbatim; pre-quote strings yourself.
// For user input prefer a parameterized `col IN (?, ?, ?)` via your driver
// instead of inlining values here.
const w = try zql.in(allocator, "id", &.{ "1", "2", "3" });
// → "id IN (1, 2, 3)"

const w = try zql.in(allocator, "role", &.{ "'admin'", "'mod'" });
// → "role IN ('admin', 'mod')"

const w = try zql.notIn(allocator, "id", &.{ "1", "2" });
// → "id NOT IN (1, 2)"

// BETWEEN (numeric)
const w = try zql.between(allocator, "age", "18", "65");
// → "age BETWEEN 18 AND 65"

// BETWEEN (datetime — quotes the values for you)
const w = try zql.betweenDates(allocator, "created_at", "2026-01-01", "2026-04-01");
// → "created_at BETWEEN '2026-01-01' AND '2026-04-01'"

// IS NULL / IS NOT NULL
const w = try zql.isNull(allocator, "deleted_at");
const w = try zql.isNotNull(allocator, "email");

// LIKE
const w = try zql.like(allocator, "name", "Eug%");
// → "name LIKE 'Eug%'"
```

Compose complex conditions with an arena for clean inline nesting:

```zig
// (role = 'admin' OR role = 'mod') AND active = 1
var arena = std.heap.ArenaAllocator.init(allocator);
defer arena.deinit();
const a = arena.allocator();

const sql = try zql.select(a, .{
    .table = "users",
    .where = try zql.all(a, &.{
        try zql.group(a, try zql.any(a, &.{ "role = 'admin'", "role = 'mod'" })),
        "active = 1",
    }),
});
```

### Aggregate functions

Two functions per aggregate: bare and aliased.

```zig
try zql.sum(a, "amount")                          // → "SUM(amount)"
try zql.sumAs(a, "amount", "total")               // → "SUM(amount) AS total"

try zql.count(a, "*")                             // → "COUNT(*)"
try zql.countAs(a, "*", "total")                  // → "COUNT(*) AS total"

try zql.avg(a, "price")                           // → "AVG(price)"
try zql.avgAs(a, "price", "avg_price")            // → "AVG(price) AS avg_price"

try zql.min(a, "price")                           // → "MIN(price)"
try zql.minAs(a, "price", "min_price")            // → "MIN(price) AS min_price"

try zql.max(a, "price")                           // → "MAX(price)"
try zql.maxAs(a, "price", "max_price")            // → "MAX(price) AS max_price"

try zql.coalesce(a, "nickname", "'anon'")         // → "COALESCE(nickname, 'anon')"
try zql.coalesceAs(a, "nickname", "'anon'", "display_name")
// → "COALESCE(nickname, 'anon') AS display_name"

try zql.cast(a, "price", "INTEGER")               // → "CAST(price AS INTEGER)"
try zql.castAs(a, "price", "INTEGER", "int_price")
// → "CAST(price AS INTEGER) AS int_price"
```

---

## Dialect-specific features (use raw SQL)

These common SQL features aren't modeled by zql because their syntax varies
across databases. Every `[]const u8` config field accepts raw SQL — and for
statements zql can't model at all, build the string directly. Each recipe
below stays compatible with zql's single-allocation memory profile (the raw
string is just another `[]const u8` zql copies through, or a one-shot
`allocPrint` you control).

### Upserts

```zig
// Postgres / modern SQLite
const sql = "INSERT INTO users (id, name) VALUES (1, 'Eugene') " ++
            "ON CONFLICT (id) DO UPDATE SET name = excluded.name";

// SQLite legacy
const sql = "INSERT OR REPLACE INTO users (id, name) VALUES (1, 'Eugene')";

// MySQL
const sql = "INSERT INTO users (id, name) VALUES (1, 'Eugene') " ++
            "ON DUPLICATE KEY UPDATE name = VALUES(name)";
```

### RETURNING

Supported by SQLite, Postgres, MariaDB (not MySQL). Append to any zql-built
statement:

```zig
const base = try zql.insert(a, .{
    .table  = "users",
    .cols   = &.{ "name", "email" },
    .values = &.{ "'Eugene'", "'e@p.io'" },
});
const sql = try std.fmt.allocPrint(a, "{s} RETURNING id, created_at", .{base});
```

### Subqueries

Pass them inline in any text field:

```zig
const sql = try zql.select(a, .{
    .table = "orders",
    .where = "total > (SELECT AVG(total) FROM orders)",
    .joins = &.{"INNER JOIN (SELECT id FROM active_users) au ON au.id = orders.user_id"},
});
```

### CTEs (`WITH ...`)

`WITH` precedes `SELECT`, which zql doesn't expose. Wrap the inner query:

```zig
const inner = try zql.select(a, .{ .table = "users", .where = "active = 1" });
const sql   = try std.fmt.allocPrint(a,
    "WITH active AS ({s}) SELECT * FROM active ORDER BY name", .{inner});
```

### Window functions

Standard syntax across modern databases, just not modeled as a typed clause.
Put the whole expression in `.cols`:

```zig
.cols = &.{
    "id",
    "ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at DESC) AS rn",
    "LAG(total, 1) OVER (ORDER BY created_at) AS prev_total",
},
```

### UNION / INTERSECT / EXCEPT

Concatenate two zql-built queries with `allocPrint`:

```zig
const a_sql = try zql.select(a, .{ .table = "users",    .where = "active = 1" });
const b_sql = try zql.select(a, .{ .table = "archived", .where = "active = 1" });
const sql   = try std.fmt.allocPrint(a, "{s} UNION ALL {s}", .{ a_sql, b_sql });
```

### Quoted identifiers (reserved words)

zql doesn't quote identifiers — quoting differs per dialect and adding the
right kind of quote would force one dialect's convention on everyone. If a
column or table is named after a reserved word, quote it yourself:

```zig
.cols = &.{ "id", "\"order\"" },   // standard SQL / Postgres / SQLite
.cols = &.{ "id", "`order`"   },   // MySQL
.cols = &.{ "id", "[order]"   },   // SQL Server
```

### `ALTER TABLE`

`ADD COLUMN`, `DROP COLUMN`, `MODIFY`/`ALTER COLUMN`, and `RENAME` all differ
across dialects. Write the statement directly:

```zig
const sql = "ALTER TABLE users ADD COLUMN nickname TEXT DEFAULT ''";
```

### Boolean and date/time literals

zql passes values through as you write them — there's no normalization. Use
each dialect's native form:

```zig
.where = "active = TRUE",                       // Postgres / MySQL
.where = "active = 1",                          // SQLite
.where = "created_at < NOW()",                  // Postgres / MySQL
.where = "created_at < datetime('now')",        // SQLite
.where = "created_at < CURRENT_TIMESTAMP",      // standard SQL — most dialects
```

---

## Running tests

```bash
zig build test
```

---

## Examples

A runnable [httpz](https://github.com/karlseguin/http.zig) web server demonstrating
users CRUD against `req.arena` lives in [`examples/`](examples/). It has its
own `build.zig.zon` so the httpz dep is isolated to the example — nothing
leaks into your project when you depend on zql.

```bash
cd examples
zig build run
# in another shell:
curl 'http://localhost:5882/users?active=1&limit=10'
```

See [`examples/src/web.zig`](examples/src/web.zig) for handlers covering
list, get, create, update, delete, and an aggregate report.

---

## License

MIT — see [LICENSE](LICENSE).
