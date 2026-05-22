# zql

A zero-dependency, database-agnostic SQL string builder for dynamic Zig code.

zql helps assemble common SQL statements from plain Zig config structs, optionals,
slices, and enums. It is intentionally not an ORM, not a database driver, and
not a SQL-injection safety layer: drivers still execute queries and bind values.

- **Pure Zig** — no C bindings, no runtime dependencies
- **Database-agnostic** — works with SQLite, PostgreSQL, rqlite, or any SQL database
- **Dynamic-query friendly** — optional filters, pagination, ordering, CRUD, simple DDL, and reusable fragments
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
// Conditionally add filters from Zig values.
var conditions: std.ArrayList([]const u8) = .empty;
defer conditions.deinit(a);            // no-op with arena, required with GPA

const is_active = true;                // trusted program state
try conditions.append(a, if (is_active) "active = 1" else "active = 0");

const start = "2026-01-01";            // trusted reporting constants
const end   = "2026-02-01";
try conditions.append(a, try zql.betweenDates(a, "created_at", start, end));

if (jurisdiction != null) {            // user/request value: use a placeholder
    try conditions.append(a, "jurisdiction = ?");
}

const sql = try zql.select(a, .{
    .table = "users",
    .where = try zql.all(a, conditions.items),
});
// Bind jurisdiction separately if that placeholder was added.
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

const is_active = true;
const start = "2026-01-01";
const end   = "2026-02-01";

const sql = try zql.select(a, .{
    .table = "users",
    .cols  = &.{ try zql.sumAs(a, "amount", "total"), "user_id" },
    .where = try zql.all(a, &.{
        if (is_active) "active = 1" else "active = 0",
        try zql.betweenDates(a, "created_at", start, end),
    }),
    .group = &.{"user_id"},
});
```

If `start` and `end` came from a request, prefer placeholders instead:

```zig
.where = "active = ? AND created_at BETWEEN ? AND ?",
// Then bind: .{ is_active, start_from_request, end_from_request }
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

Fetch the current release with Zig's package manager:

```bash
zig fetch --save https://github.com/erwagasore/zql/archive/refs/tags/v0.0.1.tar.gz
```

Or add it to your `build.zig.zon` manually:

```zig
.dependencies = .{
    .zql = .{
        .url  = "https://github.com/erwagasore/zql/archive/refs/tags/v0.0.1.tar.gz",
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

Use Zig values to decide which SQL clauses exist. zql handles clause order,
spacing, and typed fields while your driver handles bound values.

```zig
const USER_COLS = &.{ "id", "name", "email", "active", "created_at" };

const only_active = true;
const page: ?usize = 2;
const page_size: usize = 50;

const sql = try zql.select(allocator, .{
    .table  = "users",
    .cols   = USER_COLS,
    .where  = if (only_active) "active = ?" else null,
    .order  = &.{.{ .col = "created_at", .dir = .desc }},
    .limit  = if (page != null) page_size else null,
    .offset = if (page) |n| n * page_size else null,
});
// → SELECT id, name, email, active, created_at FROM users
//   WHERE active = ? ORDER BY created_at DESC LIMIT 50 OFFSET 100
// Then bind the active value with your database driver.
```

Reusable constants and runtime flags keep query shape in Zig instead of in
manual string concatenation:

```zig
const include_orders = true;
const report_cols: []const []const u8 = if (include_orders)
    &.{ "users.id", "users.email", "orders.total" }
else
    &.{ "users.id", "users.email" };

const sql = try zql.select(allocator, .{
    .table = "users",
    .cols  = report_cols,
    .joins = if (include_orders)
        &.{"INNER JOIN orders ON orders.user_id = users.id"}
    else
        &.{},
    .where = "users.active = ?",
});
```

Aggregate expressions are just Zig values too:

```zig
const total_col = try zql.countAs(allocator, "*", "total");
defer allocator.free(total_col);

const sql = try zql.select(allocator, .{
    .table  = "orders",
    .cols   = &.{ "user_id", total_col },
    .group  = &.{"user_id"},
    .having = "COUNT(*) > ?",
});
```

### INSERT

Use placeholders in `.values`, then bind the actual Zig values with your driver:

```zig
const USER_INSERT_COLS = &.{ "name", "email", "active" };

const sql = try zql.insert(allocator, .{
    .table  = "users",
    .cols   = USER_INSERT_COLS,
    .values = &.{ "?", "?", "?" },
});
// Then bind: .{ new_user.name, new_user.email, new_user.active }
```

For batch inserts, build the row shape in Zig and keep SQL placeholders separate
from the values you bind:

```zig
const row_count = users.len;
var rows = try allocator.alloc([]const []const u8, row_count);
defer allocator.free(rows);

for (rows) |*row| row.* = &.{ "?", "?" };

const sql = try zql.insertMany(allocator, .{
    .table = "users",
    .cols  = &.{ "name", "email" },
    .rows  = rows,
});
```

> Dialect-specific upserts (SQLite `INSERT OR REPLACE` / `INSERT OR IGNORE`,
> Postgres `ON CONFLICT`, MySQL `INSERT IGNORE`) are not modeled by zql — they
> would force one dialect's syntax on every user. Write those statements as
> raw SQL; see [When to use raw SQL instead](#when-to-use-raw-sql-instead).

### UPDATE

Dynamic `SET` lists are ordinary Zig slices. Add only the fields the caller sent:

```zig
var sets: std.ArrayList([]const u8) = .empty;
defer sets.deinit(allocator);

if (patch.name != null)   try sets.append(allocator, "name = ?");
if (patch.email != null)  try sets.append(allocator, "email = ?");
if (patch.active != null) try sets.append(allocator, "active = ?");

const sql = try zql.update(allocator, .{
    .table = "users",
    .set   = sets.items,
    .where = "id = ?",
});
```

### DELETE

Use the presence or absence of a Zig value to decide whether the delete is
scoped. Prefer a placeholder when the value comes from outside the program:

```zig
const maybe_id: ?u64 = 42;

const sql = try zql.delete(allocator, .{
    .table = "users",
    .where = if (maybe_id != null) "id = ?" else null,
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
For untrusted values, prefer helper inputs that are placeholders and bind the
actual values with your driver.

```zig
// AND
const w = try zql.all(allocator, &.{ "active = ?", "age > ?" });
// → "active = ? AND age > ?"

// OR
const w = try zql.any(allocator, &.{ "role = ?", "role = ?" });
// → "role = ? OR role = ?"

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

// Trusted Zig variables can be rendered as date literals.
const start = "2026-01-01";
const end   = "2026-04-01";
const trusted = try zql.betweenDates(allocator, "created_at", start, end);
// → "created_at BETWEEN '2026-01-01' AND '2026-04-01'"

// If start/end came from a request, use placeholders instead.
const w = try zql.between(allocator, "created_at", "?", "?");
// → "created_at BETWEEN ? AND ?"

// IS NULL / IS NOT NULL
const w = try zql.isNull(allocator, "deleted_at");
const w = try zql.isNotNull(allocator, "email");

// Trusted Zig variables can be rendered as LIKE literals.
const internal_prefix = "Eug%";
const trusted = try zql.like(allocator, "name", internal_prefix);
// → "name LIKE 'Eug%'"

// If the pattern came from a request, use a placeholder instead.
const w = "name LIKE ?";
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
    .values = &.{ "?", "?" },
});
const sql = try std.fmt.allocPrint(a, "{s} RETURNING id, created_at", .{base});
// Then bind the name and email values with your driver.
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
