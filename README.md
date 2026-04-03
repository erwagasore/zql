# zql

A zero-dependency, database-agnostic SQL query builder for Zig.

- **Pure Zig** — no C bindings, no runtime dependencies
- **Database-agnostic** — works with SQLite, PostgreSQL, rqlite, or any SQL database
- **Idiomatic** — follows Zig standard library memory conventions
- **Simple** — one function per statement type, plain struct config

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
var conditions = std.ArrayList([]const u8).init(a);
try conditions.append("active = 1");
if (jurisdiction) |j| {
    try conditions.append(try std.fmt.allocPrint(a, "jurisdiction = '{s}'", .{j}));
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
remaining 20% (CTEs, window functions, subqueries), every `[]const u8` field accepts
raw SQL directly:

```zig
// Window function in cols — raw string, works fine
.cols = &.{
    "id",
    "ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY created_at DESC) AS rn",
},

// Raw HAVING with subquery
.having = "SUM(total) > (SELECT AVG(total) FROM orders)",

// For queries zql cannot model at all, skip it entirely
const sql = "INSERT INTO users (id, name) ON CONFLICT(id) DO UPDATE SET name = excluded.name";
```

---

## Memory contract

Every function that returns a `[]const u8` allocates with the provided allocator.
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

// INSERT OR REPLACE INTO users (id, name) VALUES (1, 'Eugene')
const sql = try zql.insert(allocator, .{
    .table   = "users",
    .cols    = &.{ "id", "name" },
    .values  = &.{ "1", "'Eugene'" },
    .replace = true,
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

// IN / NOT IN
const w = try zql.in(allocator, "id", &.{ "1", "2", "3" });
// → "id IN (1, 2, 3)"

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

## Running tests

```bash
zig build test
```

---

## License

MIT
