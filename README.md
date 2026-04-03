# zql

A zero-dependency, database-agnostic SQL query builder for Zig.

- **Pure Zig** — no C bindings, no runtime dependencies
- **Database-agnostic** — works with SQLite, PostgreSQL, rqlite, or any SQL database
- **Idiomatic** — follows Zig standard library memory conventions
- **Simple** — one function per statement type, plain struct config

## Memory contract

Every function that returns a `[]const u8` allocates with the provided
allocator. The caller owns the result and must free it with the same allocator.

```zig
const sql = try zql.select(allocator, .{ .table = "users" });
defer allocator.free(sql); // caller frees
```

In an httpz handler, use `req.arena` — no defer needed:

```zig
const sql = try zql.select(req.arena, .{ .table = "users", .limit = 50 });
```

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .query = .{
        .url  = "https://github.com/yourname/zql/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Add to your `build.zig`:

```zig
const zql_dep = b.dependency("zql", .{});
exe.root_module.addImport("zql", query_dep.module("zql"));
```

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

// SELECT user_id, COUNT(*) as total FROM orders
// GROUP BY user_id HAVING COUNT(*) > 5
const sql = try zql.select(allocator, .{
    .table  = "orders",
    .cols   = &.{ "user_id", "COUNT(*) as total" },
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

// DELETE FROM users  (all rows)
const sql = try zql.delete(allocator, .{
    .table = "users",
});
```

### CREATE TABLE

```zig
const sql = try query.createTable(allocator, .{
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
const sql = try query.dropTable(allocator, .{
    .table     = "users",
    .if_exists = true,
});
```

### CREATE INDEX

```zig
const sql = try query.createIndex(allocator, .{
    .name          = "idx_users_email",
    .table         = "users",
    .cols          = &.{"email"},
    .unique        = true,
    .if_not_exists = true,
});
```

### WHERE helpers

Compose WHERE clauses from pieces — all return caller-owned slices:

```zig
// AND
const w = try query.all(allocator, &.{ "active = 1", "age > 18" });
// → "active = 1 AND age > 18"

// OR
const w = try query.any(allocator, &.{ "role = 'admin'", "role = 'mod'" });
// → "role = 'admin' OR role = 'mod'"

// Grouping
const w = try query.group(allocator, "a = 1 OR b = 2");
// → "(a = 1 OR b = 2)"

// NOT
const w = try query.not(allocator, "active = 1");
// → "NOT (active = 1)"

// IN
const w = try query.in(allocator, "id", &.{ "1", "2", "3" });
// → "id IN (1, 2, 3)"

// NOT IN
const w = try query.notIn(allocator, "id", &.{ "1", "2" });
// → "id NOT IN (1, 2)"

// BETWEEN
const w = try query.between(allocator, "age", "18", "65");
// → "age BETWEEN 18 AND 65"

// IS NULL / IS NOT NULL
const w = try query.isNull(allocator, "deleted_at");
const w = try query.isNotNull(allocator, "email");

// LIKE
const w = try query.like(allocator, "name", "Eug%");
// → "name LIKE 'Eug%'"
```

Compose complex conditions:

```zig
// (role = 'admin' OR role = 'mod') AND active = 1
const roles   = try query.any(allocator, &.{ "role = 'admin'", "role = 'mod'" });
defer allocator.free(roles);

const grouped = try query.group(allocator, roles);
defer allocator.free(grouped);

const w       = try query.all(allocator, &.{ grouped, "active = 1" });
defer allocator.free(w);

const sql = try zql.select(allocator, .{
    .table = "users",
    .where = w,
});
defer allocator.free(sql);
```

## Running tests

```bash
zig build test
```

## License

MIT
