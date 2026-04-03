const std   = @import("std");
const zql = @import("zql");
const testing = std.testing;

// ── SELECT ────────────────────────────────────────────────────────────────────

test "select *" {
    const sql = try zql.select(testing.allocator, .{
        .table = "users",
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("SELECT * FROM users", sql);
}

test "select columns" {
    const sql = try zql.select(testing.allocator, .{
        .table = "users",
        .cols  = &.{ "id", "name", "email" },
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("SELECT id, name, email FROM users", sql);
}

test "select with where" {
    const sql = try zql.select(testing.allocator, .{
        .table = "users",
        .cols  = &.{ "id", "name" },
        .where = "active = 1",
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("SELECT id, name FROM users WHERE active = 1", sql);
}

test "select with limit and offset" {
    const sql = try zql.select(testing.allocator, .{
        .table  = "users",
        .limit  = 10,
        .offset = 20,
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("SELECT * FROM users LIMIT 10 OFFSET 20", sql);
}

test "select with order by" {
    const sql = try zql.select(testing.allocator, .{
        .table = "users",
        .order = &.{
            .{ .col = "name",       .dir = .asc  },
            .{ .col = "created_at", .dir = .desc },
        },
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings(
        "SELECT * FROM users ORDER BY name ASC, created_at DESC",
        sql,
    );
}

test "select distinct" {
    const sql = try zql.select(testing.allocator, .{
        .table    = "users",
        .cols     = &.{"country"},
        .distinct = true,
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("SELECT DISTINCT country FROM users", sql);
}

test "select with join" {
    const sql = try zql.select(testing.allocator, .{
        .table = "users",
        .cols  = &.{ "users.id", "orders.total" },
        .joins = &.{"INNER JOIN orders ON orders.user_id = users.id"},
        .where = "users.active = 1",
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings(
        "SELECT users.id, orders.total FROM users " ++
        "INNER JOIN orders ON orders.user_id = users.id " ++
        "WHERE users.active = 1",
        sql,
    );
}

test "select with group by and having" {
    const sql = try zql.select(testing.allocator, .{
        .table  = "orders",
        .cols   = &.{ "user_id", "COUNT(*) as total" },
        .group  = &.{"user_id"},
        .having = "COUNT(*) > 5",
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings(
        "SELECT user_id, COUNT(*) as total FROM orders " ++
        "GROUP BY user_id HAVING COUNT(*) > 5",
        sql,
    );
}

test "select full" {
    const sql = try zql.select(testing.allocator, .{
        .table  = "users",
        .cols   = &.{ "id", "name", "email" },
        .where  = "active = 1",
        .order  = &.{.{ .col = "name", .dir = .asc }},
        .limit  = 50,
        .offset = 0,
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings(
        "SELECT id, name, email FROM users WHERE active = 1 ORDER BY name ASC LIMIT 50 OFFSET 0",
        sql,
    );
}

// ── INSERT ────────────────────────────────────────────────────────────────────

test "insert" {
    const sql = try zql.insert(testing.allocator, .{
        .table  = "users",
        .cols   = &.{ "name", "email" },
        .values = &.{ "'Eugene'", "'eugene@pindo.io'" },
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings(
        "INSERT INTO users (name, email) VALUES ('Eugene', 'eugene@pindo.io')",
        sql,
    );
}

test "insert or replace" {
    const sql = try zql.insert(testing.allocator, .{
        .table   = "users",
        .cols    = &.{ "id", "name" },
        .values  = &.{ "1", "'Eugene'" },
        .replace = true,
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings(
        "INSERT OR REPLACE INTO users (id, name) VALUES (1, 'Eugene')",
        sql,
    );
}

test "insert or ignore" {
    const sql = try zql.insert(testing.allocator, .{
        .table  = "users",
        .cols   = &.{"email"},
        .values = &.{"'eugene@pindo.io'"},
        .ignore = true,
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings(
        "INSERT OR IGNORE INTO users (email) VALUES ('eugene@pindo.io')",
        sql,
    );
}

test "insert cols values mismatch returns error" {
    const result = zql.insert(testing.allocator, .{
        .table  = "users",
        .cols   = &.{ "name", "email" },
        .values = &.{"'Eugene'"},
    });
    try testing.expectError(error.ColsValuesMismatch, result);
}

// ── INSERT MANY ───────────────────────────────────────────────────────────────

test "insert many" {
    const sql = try zql.insertMany(testing.allocator, .{
        .table = "users",
        .cols  = &.{ "name", "email" },
        .rows  = &.{
            &.{ "'Eugene'", "'eugene@pindo.io'" },
            &.{ "'Alice'",  "'alice@example.com'" },
        },
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings(
        "INSERT INTO users (name, email) VALUES ('Eugene', 'eugene@pindo.io'), ('Alice', 'alice@example.com')",
        sql,
    );
}

test "insert many no rows returns error" {
    const result = zql.insertMany(testing.allocator, .{
        .table = "users",
        .cols  = &.{"name"},
        .rows  = &.{},
    });
    try testing.expectError(error.NoRows, result);
}

// ── UPDATE ────────────────────────────────────────────────────────────────────

test "update" {
    const sql = try zql.update(testing.allocator, .{
        .table = "users",
        .set   = &.{ "name = 'Eugene'", "active = 1" },
        .where = "id = 1",
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings(
        "UPDATE users SET name = 'Eugene', active = 1 WHERE id = 1",
        sql,
    );
}

test "update without where updates all rows" {
    const sql = try zql.update(testing.allocator, .{
        .table = "users",
        .set   = &.{"active = 0"},
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("UPDATE users SET active = 0", sql);
}

test "update no set clauses returns error" {
    const result = zql.update(testing.allocator, .{
        .table = "users",
        .set   = &.{},
        .where = "id = 1",
    });
    try testing.expectError(error.NoSetClauses, result);
}

// ── DELETE ────────────────────────────────────────────────────────────────────

test "delete with where" {
    const sql = try zql.delete(testing.allocator, .{
        .table = "users",
        .where = "id = 1",
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("DELETE FROM users WHERE id = 1", sql);
}

test "delete all rows" {
    const sql = try zql.delete(testing.allocator, .{
        .table = "users",
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("DELETE FROM users", sql);
}

// ── CREATE TABLE ──────────────────────────────────────────────────────────────

test "create table" {
    const sql = try zql.createTable(testing.allocator, .{
        .table = "users",
        .cols  = &.{
            .{ .name = "id",    .type = "INTEGER", .constraints = "PRIMARY KEY AUTOINCREMENT" },
            .{ .name = "name",  .type = "TEXT",    .constraints = "NOT NULL" },
            .{ .name = "email", .type = "TEXT",    .constraints = "NOT NULL UNIQUE" },
        },
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings(
        "CREATE TABLE users (" ++
        "id INTEGER PRIMARY KEY AUTOINCREMENT, " ++
        "name TEXT NOT NULL, " ++
        "email TEXT NOT NULL UNIQUE)",
        sql,
    );
}

test "create table if not exists" {
    const sql = try zql.createTable(testing.allocator, .{
        .table         = "users",
        .if_not_exists = true,
        .cols          = &.{
            .{ .name = "id", .type = "INTEGER" },
        },
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS users (id INTEGER)",
        sql,
    );
}

// ── DROP TABLE ────────────────────────────────────────────────────────────────

test "drop table" {
    const sql = try zql.dropTable(testing.allocator, .{
        .table = "users",
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("DROP TABLE users", sql);
}

test "drop table if exists" {
    const sql = try zql.dropTable(testing.allocator, .{
        .table     = "users",
        .if_exists = true,
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("DROP TABLE IF EXISTS users", sql);
}

// ── CREATE INDEX ──────────────────────────────────────────────────────────────

test "create index" {
    const sql = try zql.createIndex(testing.allocator, .{
        .name  = "idx_users_email",
        .table = "users",
        .cols  = &.{"email"},
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings(
        "CREATE INDEX idx_users_email ON users (email)",
        sql,
    );
}

test "create unique index if not exists" {
    const sql = try zql.createIndex(testing.allocator, .{
        .name          = "idx_users_email",
        .table         = "users",
        .cols          = &.{"email"},
        .unique        = true,
        .if_not_exists = true,
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings(
        "CREATE UNIQUE INDEX IF NOT EXISTS idx_users_email ON users (email)",
        sql,
    );
}

// ── WHERE helpers ─────────────────────────────────────────────────────────────

test "where all" {
    const w = try zql.all(testing.allocator, &.{ "active = 1", "age > 18" });
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("active = 1 AND age > 18", w);
}

test "where any" {
    const w = try zql.any(testing.allocator, &.{ "role = 'admin'", "role = 'mod'" });
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("role = 'admin' OR role = 'mod'", w);
}

test "where group" {
    const w = try zql.group(testing.allocator, "a = 1 OR b = 2");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("(a = 1 OR b = 2)", w);
}

test "where not" {
    const w = try zql.not(testing.allocator, "active = 1");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("NOT (active = 1)", w);
}

test "where in" {
    const w = try zql.in(testing.allocator, "id", &.{ "1", "2", "3" });
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("id IN (1, 2, 3)", w);
}

test "where not in" {
    const w = try zql.notIn(testing.allocator, "id", &.{ "1", "2" });
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("id NOT IN (1, 2)", w);
}

test "where between" {
    const w = try zql.between(testing.allocator, "age", "18", "65");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("age BETWEEN 18 AND 65", w);
}

test "where is null" {
    const w = try zql.isNull(testing.allocator, "deleted_at");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("deleted_at IS NULL", w);
}

test "where is not null" {
    const w = try zql.isNotNull(testing.allocator, "email");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("email IS NOT NULL", w);
}

test "where like" {
    const w = try zql.like(testing.allocator, "name", "Eug%");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("name LIKE 'Eug%'", w);
}

// ── Composition ───────────────────────────────────────────────────────────────

test "compose where with all and any" {
    // (role = 'admin' OR role = 'mod') AND active = 1
    const roles = try zql.any(testing.allocator, &.{ "role = 'admin'", "role = 'mod'" });
    defer testing.allocator.free(roles);

    const roles_grouped = try zql.group(testing.allocator, roles);
    defer testing.allocator.free(roles_grouped);

    const w = try zql.all(testing.allocator, &.{ roles_grouped, "active = 1" });
    defer testing.allocator.free(w);

    const sql = try zql.select(testing.allocator, .{
        .table = "users",
        .where = w,
    });
    defer testing.allocator.free(sql);

    try testing.expectEqualStrings(
        "SELECT * FROM users WHERE (role = 'admin' OR role = 'mod') AND active = 1",
        sql,
    );
}

test "jurisdiction query example" {
    // Simulate selecting active Rwandan users — the pattern from our discussion
    const w = try zql.all(testing.allocator, &.{
        "active = 1",
        "jurisdiction = 'RW'",
    });
    defer testing.allocator.free(w);

    const sql = try zql.select(testing.allocator, .{
        .table  = "users",
        .cols   = &.{ "id", "name", "email" },
        .where  = w,
        .order  = &.{.{ .col = "name", .dir = .asc }},
        .limit  = 50,
    });
    defer testing.allocator.free(sql);

    try testing.expectEqualStrings(
        "SELECT id, name, email FROM users " ++
        "WHERE active = 1 AND jurisdiction = 'RW' " ++
        "ORDER BY name ASC LIMIT 50",
        sql,
    );
}

// ── betweenDates ──────────────────────────────────────────────────────────────

test "betweenDates" {
    const w = try zql.betweenDates(
        testing.allocator,
        "sms.created_at",
        "2026-03-01 00:00:00",
        "2026-04-01 00:00:00",
    );
    defer testing.allocator.free(w);
    try testing.expectEqualStrings(
        "sms.created_at BETWEEN '2026-03-01 00:00:00' AND '2026-04-01 00:00:00'",
        w,
    );
}

// ── Aggregates ────────────────────────────────────────────────────────────────

test "sum with alias" {
    const s = try zql.sum(testing.allocator, "sms_item_count", "total_sms_items");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("SUM(sms_item_count) AS total_sms_items", s);
}

test "sum without alias" {
    const s = try zql.sum(testing.allocator, "amount", null);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("SUM(amount)", s);
}

test "count star" {
    const s = try zql.count(testing.allocator, "*", "total");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("COUNT(*) AS total", s);
}

test "count without alias" {
    const s = try zql.count(testing.allocator, "*", null);
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("COUNT(*)", s);
}

test "avg with alias" {
    const s = try zql.avg(testing.allocator, "price", "avg_price");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("AVG(price) AS avg_price", s);
}

test "min with alias" {
    const s = try zql.min(testing.allocator, "price", "min_price");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("MIN(price) AS min_price", s);
}

test "max with alias" {
    const s = try zql.max(testing.allocator, "price", "max_price");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("MAX(price) AS max_price", s);
}

test "coalesce" {
    const s = try zql.coalesce(testing.allocator, "nickname", "'anonymous'");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("COALESCE(nickname, 'anonymous')", s);
}

test "cast" {
    const s = try zql.cast(testing.allocator, "price", "INTEGER");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("CAST(price AS INTEGER)", s);
}

// ── Real world query: sms aggregation ────────────────────────────────────────

test "sms aggregation query with arena" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sql = try zql.select(a, .{
        .table = "sms",
        .cols  = &.{
            try zql.sum(a, "sms_item_count", "total_sms_items"),
            "sms.retry_count",
        },
        .where = try zql.all(a, &.{
            "account_id = '74'",
            try zql.betweenDates(a, "sms.created_at", "2026-03-01 00:00:00", "2026-04-01 00:00:00"),
        }),
        .group = &.{"retry_count"},
    });

    try testing.expectEqualStrings(
        "SELECT SUM(sms_item_count) AS total_sms_items, sms.retry_count" ++
        " FROM sms" ++
        " WHERE account_id = '74'" ++
        " AND sms.created_at BETWEEN '2026-03-01 00:00:00' AND '2026-04-01 00:00:00'" ++
        " GROUP BY retry_count",
        sql,
    );
}
