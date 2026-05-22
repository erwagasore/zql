//! zql — A zero-dependency, database-agnostic SQL query builder for Zig.
//!
//! Each statement has two entry points:
//!
//!   1. Allocator API — returns a caller-owned slice. Use when you just want
//!      a SQL string:
//!
//!        const sql = try zql.select(gpa, .{ .table = "users" });
//!        defer gpa.free(sql);
//!
//!   2. Writer API — writes directly to any `std.Io.Writer`. Use when you
//!      already have a writer (file, socket, ArrayList buffer) to avoid the
//!      intermediate allocation:
//!
//!        try zql.writeSelect(&w, .{ .table = "users" });

const std       = @import("std");
const Allocator = std.mem.Allocator;
const Writer    = std.Io.Writer;
const testing   = std.testing;

// ── Shared types ──────────────────────────────────────────────────────────────

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

/// Union of every validation error any `writeX` function can return. Use as
/// `zql.Error || zql.Writer.Error || Allocator.Error` for a catch-all in
/// callers, or catch the specific variant a function emits (see each
/// `writeX` signature for the precise subset).
pub const Error = error{
    ColsValuesMismatch,
    NoColumns,
    NoIndexName,
    NoRows,
    NoSetClauses,
    NoTable,
    NoValues,
};

// ── Internal: comma-separated list ────────────────────────────────────────────

fn writeList(w: *Writer, items: []const []const u8) Writer.Error!void {
    for (items, 0..) |it, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(it);
    }
}

// ── Single-allocation renderer ────────────────────────────────────────────────

/// Two-pass render: counts the exact output size with a `Discarding` writer,
/// allocates that many bytes once, then fills them with a `fixed` writer.
/// One allocation per call — no grow-reallocs, no shrink-to-fit, no wasted
/// bytes. Important for arena allocators, where intermediate reallocs would
/// accumulate as unfreed memory until `arena.deinit()`.
///
/// Exposed so callers can add their own statement types using the same
/// single-allocation pattern. Pair a config struct with a writer function
/// `fn(*std.Io.Writer, Cfg) !void` and pass both here:
///
///     pub const MyConfig = struct { ... };
///     pub fn writeMy(w: *std.Io.Writer, cfg: MyConfig) !void { ... }
///     pub fn my(gpa: Allocator, cfg: MyConfig) ![]u8 {
///         return zql.renderOwned(gpa, cfg, writeMy);
///     }
pub fn renderOwned(gpa: Allocator, cfg: anytype, comptime writeFn: anytype) ![]u8 {
    var scratch: [64]u8 = undefined;
    var d: Writer.Discarding = .init(&scratch);
    try writeFn(&d.writer, cfg);

    const buf = try gpa.alloc(u8, @intCast(d.fullCount()));
    errdefer gpa.free(buf);

    var fw: Writer = .fixed(buf);
    try writeFn(&fw, cfg);
    return buf;
}

// ── SELECT ────────────────────────────────────────────────────────────────────

pub const SelectConfig = struct {
    table:    []const u8         = "",
    cols:     []const []const u8 = &.{},
    where:    ?[]const u8        = null,
    order:    []const Order      = &.{},
    limit:    ?usize             = null,
    offset:   ?usize             = null,
    joins:    []const []const u8 = &.{},
    group:    []const []const u8 = &.{},
    having:   ?[]const u8        = null,
    distinct: bool               = false,
};

pub fn select(gpa: Allocator, cfg: SelectConfig) ![]u8 {
    return renderOwned(gpa, cfg, writeSelect);
}

pub fn writeSelect(w: *Writer, cfg: SelectConfig) (Writer.Error || error{NoTable})!void {
    if (cfg.table.len == 0) return error.NoTable;

    try w.writeAll("SELECT ");
    if (cfg.distinct) try w.writeAll("DISTINCT ");
    if (cfg.cols.len == 0) try w.writeByte('*') else try writeList(w, cfg.cols);
    try w.print(" FROM {s}", .{cfg.table});

    for (cfg.joins) |j| try w.print(" {s}", .{j});
    if (cfg.where)  |x| try w.print(" WHERE {s}", .{x});

    if (cfg.group.len > 0) {
        try w.writeAll(" GROUP BY ");
        try writeList(w, cfg.group);
    }
    if (cfg.having) |x| try w.print(" HAVING {s}", .{x});

    if (cfg.order.len > 0) {
        try w.writeAll(" ORDER BY ");
        for (cfg.order, 0..) |t, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll(t.col);
            try w.writeAll(if (t.dir == .asc) " ASC" else " DESC");
        }
    }

    if (cfg.limit)  |x| try w.print(" LIMIT {d}",  .{x});
    if (cfg.offset) |x| try w.print(" OFFSET {d}", .{x});
}

test "select *" {
    const sql = try select(testing.allocator, .{ .table = "users" });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("SELECT * FROM users", sql);
}

test "select columns" {
    const sql = try select(testing.allocator, .{
        .table = "users",
        .cols  = &.{ "id", "name", "email" },
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("SELECT id, name, email FROM users", sql);
}

test "select with where" {
    const sql = try select(testing.allocator, .{
        .table = "users",
        .cols  = &.{ "id", "name" },
        .where = "active = 1",
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("SELECT id, name FROM users WHERE active = 1", sql);
}

test "select with limit and offset" {
    const sql = try select(testing.allocator, .{
        .table  = "users",
        .limit  = 10,
        .offset = 20,
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("SELECT * FROM users LIMIT 10 OFFSET 20", sql);
}

test "select with order by" {
    const sql = try select(testing.allocator, .{
        .table = "users",
        .order = &.{
            .{ .col = "name",       .dir = .asc },
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
    const sql = try select(testing.allocator, .{
        .table    = "users",
        .cols     = &.{"country"},
        .distinct = true,
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("SELECT DISTINCT country FROM users", sql);
}

test "select with join" {
    const sql = try select(testing.allocator, .{
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
    const sql = try select(testing.allocator, .{
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
    const sql = try select(testing.allocator, .{
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

test "select missing table returns error" {
    try testing.expectError(error.NoTable, select(testing.allocator, .{}));
}

// ── INSERT ────────────────────────────────────────────────────────────────────

pub const InsertConfig = struct {
    table:  []const u8         = "",
    cols:   []const []const u8 = &.{},
    values: []const []const u8 = &.{},
};

pub fn insert(gpa: Allocator, cfg: InsertConfig) ![]u8 {
    return renderOwned(gpa, cfg, writeInsert);
}

pub fn writeInsert(w: *Writer, cfg: InsertConfig) (Writer.Error || error{ NoTable, NoColumns, NoValues, ColsValuesMismatch })!void {
    if (cfg.table.len == 0) return error.NoTable;
    if (cfg.cols.len == 0) return error.NoColumns;
    if (cfg.values.len == 0) return error.NoValues;
    if (cfg.cols.len != cfg.values.len) return error.ColsValuesMismatch;

    try w.print("INSERT INTO {s} (", .{cfg.table});
    try writeList(w, cfg.cols);
    try w.writeAll(") VALUES (");
    try writeList(w, cfg.values);
    try w.writeByte(')');
}

test "insert" {
    const sql = try insert(testing.allocator, .{
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

test "insert cols values mismatch returns error" {
    try testing.expectError(error.ColsValuesMismatch, insert(testing.allocator, .{
        .table  = "users",
        .cols   = &.{ "name", "email" },
        .values = &.{"'Eugene'"},
    }));
}

test "insert missing required fields return errors" {
    try testing.expectError(error.NoTable, insert(testing.allocator, .{
        .cols   = &.{"name"},
        .values = &.{"?"},
    }));
    try testing.expectError(error.NoColumns, insert(testing.allocator, .{
        .table  = "users",
        .values = &.{"?"},
    }));
    try testing.expectError(error.NoValues, insert(testing.allocator, .{
        .table = "users",
        .cols  = &.{"name"},
    }));
}

// ── INSERT MANY ───────────────────────────────────────────────────────────────

pub const InsertManyConfig = struct {
    table: []const u8                 = "",
    cols:  []const []const u8         = &.{},
    rows:  []const []const []const u8 = &.{},
};

pub fn insertMany(gpa: Allocator, cfg: InsertManyConfig) ![]u8 {
    return renderOwned(gpa, cfg, writeInsertMany);
}

pub fn writeInsertMany(w: *Writer, cfg: InsertManyConfig) (Writer.Error || error{ NoTable, NoColumns, NoRows, ColsValuesMismatch })!void {
    if (cfg.table.len == 0) return error.NoTable;
    if (cfg.cols.len == 0) return error.NoColumns;
    if (cfg.rows.len == 0) return error.NoRows;
    for (cfg.rows) |row| if (row.len != cfg.cols.len) return error.ColsValuesMismatch;

    try w.print("INSERT INTO {s} (", .{cfg.table});
    try writeList(w, cfg.cols);
    try w.writeAll(") VALUES ");

    for (cfg.rows, 0..) |row, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeByte('(');
        try writeList(w, row);
        try w.writeByte(')');
    }
}

test "insert many" {
    const sql = try insertMany(testing.allocator, .{
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
    try testing.expectError(error.NoRows, insertMany(testing.allocator, .{
        .table = "users",
        .cols  = &.{"name"},
        .rows  = &.{},
    }));
}

test "insert many missing required fields return errors" {
    try testing.expectError(error.NoTable, insertMany(testing.allocator, .{
        .cols = &.{"name"},
        .rows = &.{&.{"?"}},
    }));
    try testing.expectError(error.NoColumns, insertMany(testing.allocator, .{
        .table = "users",
        .rows  = &.{&.{"?"}},
    }));
}

// ── UPDATE ────────────────────────────────────────────────────────────────────

pub const UpdateConfig = struct {
    table: []const u8         = "",
    set:   []const []const u8 = &.{},
    where: ?[]const u8        = null,
};

pub fn update(gpa: Allocator, cfg: UpdateConfig) ![]u8 {
    return renderOwned(gpa, cfg, writeUpdate);
}

pub fn writeUpdate(w: *Writer, cfg: UpdateConfig) (Writer.Error || error{ NoTable, NoSetClauses })!void {
    if (cfg.table.len == 0) return error.NoTable;
    if (cfg.set.len == 0) return error.NoSetClauses;

    try w.print("UPDATE {s} SET ", .{cfg.table});
    try writeList(w, cfg.set);
    if (cfg.where) |x| try w.print(" WHERE {s}", .{x});
}

test "update" {
    const sql = try update(testing.allocator, .{
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
    const sql = try update(testing.allocator, .{
        .table = "users",
        .set   = &.{"active = 0"},
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("UPDATE users SET active = 0", sql);
}

test "update no set clauses returns error" {
    try testing.expectError(error.NoSetClauses, update(testing.allocator, .{
        .table = "users",
        .set   = &.{},
        .where = "id = 1",
    }));
}

test "update missing table returns error" {
    try testing.expectError(error.NoTable, update(testing.allocator, .{
        .set = &.{"active = ?"},
    }));
}

// ── DELETE ────────────────────────────────────────────────────────────────────

pub const DeleteConfig = struct {
    table: []const u8  = "",
    where: ?[]const u8 = null,
};

pub fn delete(gpa: Allocator, cfg: DeleteConfig) ![]u8 {
    return renderOwned(gpa, cfg, writeDelete);
}

pub fn writeDelete(w: *Writer, cfg: DeleteConfig) (Writer.Error || error{NoTable})!void {
    if (cfg.table.len == 0) return error.NoTable;

    try w.print("DELETE FROM {s}", .{cfg.table});
    if (cfg.where) |x| try w.print(" WHERE {s}", .{x});
}

test "delete with where" {
    const sql = try delete(testing.allocator, .{
        .table = "users",
        .where = "id = 1",
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("DELETE FROM users WHERE id = 1", sql);
}

test "delete all rows" {
    const sql = try delete(testing.allocator, .{ .table = "users" });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("DELETE FROM users", sql);
}

test "delete missing table returns error" {
    try testing.expectError(error.NoTable, delete(testing.allocator, .{}));
}

// ── CREATE TABLE ──────────────────────────────────────────────────────────────

pub const CreateTableConfig = struct {
    table:         []const u8     = "",
    cols:          []const Column = &.{},
    if_not_exists: bool           = false,
};

pub fn createTable(gpa: Allocator, cfg: CreateTableConfig) ![]u8 {
    return renderOwned(gpa, cfg, writeCreateTable);
}

pub fn writeCreateTable(w: *Writer, cfg: CreateTableConfig) (Writer.Error || error{ NoTable, NoColumns })!void {
    if (cfg.table.len == 0) return error.NoTable;
    if (cfg.cols.len == 0) return error.NoColumns;

    try w.writeAll(if (cfg.if_not_exists) "CREATE TABLE IF NOT EXISTS " else "CREATE TABLE ");
    try w.print("{s} (", .{cfg.table});

    for (cfg.cols, 0..) |c, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("{s} {s}", .{ c.name, c.type });
        if (c.constraints.len > 0) try w.print(" {s}", .{c.constraints});
    }
    try w.writeByte(')');
}

test "create table" {
    const sql = try createTable(testing.allocator, .{
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
    const sql = try createTable(testing.allocator, .{
        .table         = "users",
        .if_not_exists = true,
        .cols          = &.{.{ .name = "id", .type = "INTEGER" }},
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("CREATE TABLE IF NOT EXISTS users (id INTEGER)", sql);
}

test "create table missing required fields return errors" {
    try testing.expectError(error.NoTable, createTable(testing.allocator, .{
        .cols = &.{.{ .name = "id", .type = "INTEGER" }},
    }));
    try testing.expectError(error.NoColumns, createTable(testing.allocator, .{
        .table = "users",
    }));
}

// ── DROP TABLE ────────────────────────────────────────────────────────────────

pub const DropTableConfig = struct {
    table:     []const u8 = "",
    if_exists: bool       = false,
};

pub fn dropTable(gpa: Allocator, cfg: DropTableConfig) ![]u8 {
    return renderOwned(gpa, cfg, writeDropTable);
}

pub fn writeDropTable(w: *Writer, cfg: DropTableConfig) (Writer.Error || error{NoTable})!void {
    if (cfg.table.len == 0) return error.NoTable;

    try w.writeAll(if (cfg.if_exists) "DROP TABLE IF EXISTS " else "DROP TABLE ");
    try w.writeAll(cfg.table);
}

test "drop table" {
    const sql = try dropTable(testing.allocator, .{ .table = "users" });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("DROP TABLE users", sql);
}

test "drop table if exists" {
    const sql = try dropTable(testing.allocator, .{
        .table     = "users",
        .if_exists = true,
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("DROP TABLE IF EXISTS users", sql);
}

test "drop table missing table returns error" {
    try testing.expectError(error.NoTable, dropTable(testing.allocator, .{}));
}

// ── CREATE INDEX ──────────────────────────────────────────────────────────────

pub const CreateIndexConfig = struct {
    name:          []const u8         = "",
    table:         []const u8         = "",
    cols:          []const []const u8 = &.{},
    unique:        bool               = false,
    if_not_exists: bool               = false,
};

pub fn createIndex(gpa: Allocator, cfg: CreateIndexConfig) ![]u8 {
    return renderOwned(gpa, cfg, writeCreateIndex);
}

pub fn writeCreateIndex(w: *Writer, cfg: CreateIndexConfig) (Writer.Error || error{ NoIndexName, NoTable, NoColumns })!void {
    if (cfg.name.len == 0) return error.NoIndexName;
    if (cfg.table.len == 0) return error.NoTable;
    if (cfg.cols.len == 0) return error.NoColumns;

    try w.writeAll("CREATE ");
    if (cfg.unique)        try w.writeAll("UNIQUE ");
    try w.writeAll("INDEX ");
    if (cfg.if_not_exists) try w.writeAll("IF NOT EXISTS ");
    try w.print("{s} ON {s} (", .{ cfg.name, cfg.table });
    try writeList(w, cfg.cols);
    try w.writeByte(')');
}

test "create index" {
    const sql = try createIndex(testing.allocator, .{
        .name  = "idx_users_email",
        .table = "users",
        .cols  = &.{"email"},
    });
    defer testing.allocator.free(sql);
    try testing.expectEqualStrings("CREATE INDEX idx_users_email ON users (email)", sql);
}

test "create unique index if not exists" {
    const sql = try createIndex(testing.allocator, .{
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

test "create index missing required fields return errors" {
    try testing.expectError(error.NoIndexName, createIndex(testing.allocator, .{
        .table = "users",
        .cols  = &.{"email"},
    }));
    try testing.expectError(error.NoTable, createIndex(testing.allocator, .{
        .name = "idx_users_email",
        .cols = &.{"email"},
    }));
    try testing.expectError(error.NoColumns, createIndex(testing.allocator, .{
        .name  = "idx_users_email",
        .table = "users",
    }));
}

// ── WHERE helpers ─────────────────────────────────────────────────────────────
//
// Composable fragment builders. Each returns a caller-owned slice; pass results
// to `.where`/`.having` or compose with `all`/`any`/`group`/`not`.

pub fn eq(gpa: Allocator, col: []const u8, value: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s} = {s}", .{ col, value });
}

pub fn ne(gpa: Allocator, col: []const u8, value: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s} <> {s}", .{ col, value });
}

pub fn gt(gpa: Allocator, col: []const u8, value: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s} > {s}", .{ col, value });
}

pub fn lt(gpa: Allocator, col: []const u8, value: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s} < {s}", .{ col, value });
}

pub fn ge(gpa: Allocator, col: []const u8, value: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s} >= {s}", .{ col, value });
}

pub fn le(gpa: Allocator, col: []const u8, value: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s} <= {s}", .{ col, value });
}

pub fn all(gpa: Allocator, conditions: []const []const u8) ![]u8 {
    return std.mem.join(gpa, " AND ", conditions);
}

pub fn any(gpa: Allocator, conditions: []const []const u8) ![]u8 {
    return std.mem.join(gpa, " OR ", conditions);
}

pub fn group(gpa: Allocator, condition: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "({s})", .{condition});
}

pub fn not(gpa: Allocator, condition: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "NOT ({s})", .{condition});
}

pub fn in(gpa: Allocator, col: []const u8, values: []const []const u8) ![]u8 {
    return renderOwned(gpa, InCtx{ .col = col, .op = "IN", .values = values }, writeIn);
}

pub fn notIn(gpa: Allocator, col: []const u8, values: []const []const u8) ![]u8 {
    return renderOwned(gpa, InCtx{ .col = col, .op = "NOT IN", .values = values }, writeIn);
}

const InCtx = struct {
    col:    []const u8,
    op:     []const u8,
    values: []const []const u8,
};

fn writeIn(w: *Writer, ctx: InCtx) Writer.Error!void {
    try w.print("{s} {s} (", .{ ctx.col, ctx.op });
    try writeList(w, ctx.values);
    try w.writeByte(')');
}

pub fn between(gpa: Allocator, col: []const u8, low: []const u8, high: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s} BETWEEN {s} AND {s}", .{ col, low, high });
}

/// `betweenDates` is like `between` but quotes the values — handy for ISO8601
/// timestamps that the caller has not pre-quoted.
pub fn betweenDates(gpa: Allocator, col: []const u8, from: []const u8, to: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s} BETWEEN '{s}' AND '{s}'", .{ col, from, to });
}

pub fn isNull(gpa: Allocator, col: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s} IS NULL", .{col});
}

pub fn isNotNull(gpa: Allocator, col: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s} IS NOT NULL", .{col});
}

pub fn like(gpa: Allocator, col: []const u8, pattern: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s} LIKE '{s}'", .{ col, pattern });
}

test "where eq" {
    const w = try eq(testing.allocator, "status", "pending");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("status = pending", w);
}

test "where ne" {
    const w = try ne(testing.allocator, "role", "admin");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("role <> admin", w);
}

test "where gt" {
    const w = try gt(testing.allocator, "age", "18");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("age > 18", w);
}

test "where lt" {
    const w = try lt(testing.allocator, "age", "65");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("age < 65", w);
}

test "where ge" {
    const w = try ge(testing.allocator, "score", "100");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("score >= 100", w);
}

test "where le" {
    const w = try le(testing.allocator, "score", "500");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("score <= 500", w);
}

test "where all" {
    const w = try all(testing.allocator, &.{ "active = 1", "age > 18" });
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("active = 1 AND age > 18", w);
}

test "where any" {
    const w = try any(testing.allocator, &.{ "role = 'admin'", "role = 'mod'" });
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("role = 'admin' OR role = 'mod'", w);
}

test "where group" {
    const w = try group(testing.allocator, "a = 1 OR b = 2");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("(a = 1 OR b = 2)", w);
}

test "where not" {
    const w = try not(testing.allocator, "active = 1");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("NOT (active = 1)", w);
}

test "where in" {
    const w = try in(testing.allocator, "id", &.{ "1", "2", "3" });
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("id IN (1, 2, 3)", w);
}

test "where not in" {
    const w = try notIn(testing.allocator, "id", &.{ "1", "2" });
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("id NOT IN (1, 2)", w);
}

test "where between" {
    const w = try between(testing.allocator, "age", "18", "65");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("age BETWEEN 18 AND 65", w);
}

test "where is null" {
    const w = try isNull(testing.allocator, "deleted_at");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("deleted_at IS NULL", w);
}

test "where is not null" {
    const w = try isNotNull(testing.allocator, "email");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("email IS NOT NULL", w);
}

test "where like" {
    const w = try like(testing.allocator, "name", "Eug%");
    defer testing.allocator.free(w);
    try testing.expectEqualStrings("name LIKE 'Eug%'", w);
}

test "betweenDates" {
    const w = try betweenDates(
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

test "compose where with all and any" {
    const a = testing.allocator;
    const roles   = try any(a, &.{ "role = 'admin'", "role = 'mod'" });
    defer a.free(roles);
    const grouped = try group(a, roles);
    defer a.free(grouped);
    const w       = try all(a, &.{ grouped, "active = 1" });
    defer a.free(w);

    const sql = try select(a, .{ .table = "users", .where = w });
    defer a.free(sql);

    try testing.expectEqualStrings(
        "SELECT * FROM users WHERE (role = 'admin' OR role = 'mod') AND active = 1",
        sql,
    );
}

// ── Aggregate / scalar functions ──────────────────────────────────────────────
//
// Two variants per function: bare (`SUM(col)`) and aliased (`SUM(col) AS x`).

pub fn sum(gpa: Allocator, col: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "SUM({s})", .{col});
}

pub fn sumAs(gpa: Allocator, col: []const u8, alias: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "SUM({s}) AS {s}", .{ col, alias });
}

pub fn count(gpa: Allocator, col: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "COUNT({s})", .{col});
}

pub fn countAs(gpa: Allocator, col: []const u8, alias: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "COUNT({s}) AS {s}", .{ col, alias });
}

pub fn avg(gpa: Allocator, col: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "AVG({s})", .{col});
}

pub fn avgAs(gpa: Allocator, col: []const u8, alias: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "AVG({s}) AS {s}", .{ col, alias });
}

pub fn min(gpa: Allocator, col: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "MIN({s})", .{col});
}

pub fn minAs(gpa: Allocator, col: []const u8, alias: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "MIN({s}) AS {s}", .{ col, alias });
}

pub fn max(gpa: Allocator, col: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "MAX({s})", .{col});
}

pub fn maxAs(gpa: Allocator, col: []const u8, alias: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "MAX({s}) AS {s}", .{ col, alias });
}

pub fn coalesce(gpa: Allocator, col: []const u8, fallback: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "COALESCE({s}, {s})", .{ col, fallback });
}

pub fn coalesceAs(gpa: Allocator, col: []const u8, fallback: []const u8, alias: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "COALESCE({s}, {s}) AS {s}", .{ col, fallback, alias });
}

pub fn cast(gpa: Allocator, col: []const u8, as_type: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "CAST({s} AS {s})", .{ col, as_type });
}

pub fn castAs(gpa: Allocator, col: []const u8, as_type: []const u8, alias: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "CAST({s} AS {s}) AS {s}", .{ col, as_type, alias });
}

test "sum bare" {
    const s = try sum(testing.allocator, "amount");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("SUM(amount)", s);
}

test "count bare" {
    const s = try count(testing.allocator, "*");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("COUNT(*)", s);
}

test "avg bare" {
    const s = try avg(testing.allocator, "price");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("AVG(price)", s);
}

test "min bare" {
    const s = try min(testing.allocator, "price");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("MIN(price)", s);
}

test "max bare" {
    const s = try max(testing.allocator, "price");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("MAX(price)", s);
}

test "coalesce bare" {
    const s = try coalesce(testing.allocator, "nickname", "'anonymous'");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("COALESCE(nickname, 'anonymous')", s);
}

test "cast bare" {
    const s = try cast(testing.allocator, "price", "INTEGER");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("CAST(price AS INTEGER)", s);
}

test "sumAs" {
    const s = try sumAs(testing.allocator, "sms_item_count", "total_sms_items");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("SUM(sms_item_count) AS total_sms_items", s);
}

test "countAs" {
    const s = try countAs(testing.allocator, "*", "total");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("COUNT(*) AS total", s);
}

test "avgAs" {
    const s = try avgAs(testing.allocator, "price", "avg_price");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("AVG(price) AS avg_price", s);
}

test "minAs" {
    const s = try minAs(testing.allocator, "price", "min_price");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("MIN(price) AS min_price", s);
}

test "maxAs" {
    const s = try maxAs(testing.allocator, "price", "max_price");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("MAX(price) AS max_price", s);
}

test "coalesceAs" {
    const s = try coalesceAs(testing.allocator, "nickname", "'anonymous'", "display_name");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("COALESCE(nickname, 'anonymous') AS display_name", s);
}

test "castAs" {
    const s = try castAs(testing.allocator, "price", "INTEGER", "int_price");
    defer testing.allocator.free(s);
    try testing.expectEqualStrings("CAST(price AS INTEGER) AS int_price", s);
}

// ── Real-world integration tests ──────────────────────────────────────────────

test "sms aggregation query" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sql = try select(a, .{
        .table = "sms",
        .cols  = &.{
            try sumAs(a, "sms_item_count", "total_sms_items"),
            "sms.retry_count",
        },
        .where = try all(a, &.{
            "account_id = '74'",
            try betweenDates(a, "sms.created_at", "2026-03-01 00:00:00", "2026-04-01 00:00:00"),
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

test "jurisdiction query" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sql = try select(a, .{
        .table = "users",
        .cols  = &.{ "id", "name", "email" },
        .where = try all(a, &.{ "active = 1", "jurisdiction = 'RW'" }),
        .order = &.{.{ .col = "name", .dir = .asc }},
        .limit = 50,
    });

    try testing.expectEqualStrings(
        "SELECT id, name, email FROM users " ++
        "WHERE active = 1 AND jurisdiction = 'RW' " ++
        "ORDER BY name ASC LIMIT 50",
        sql,
    );
}

// ── Writer API spot check ─────────────────────────────────────────────────────
//
// Confirms the lower-level `writeX` functions emit identically to the allocator
// variants when given a fixed buffer.

test "writeSelect via fixed buffer" {
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeSelect(&w, .{ .table = "users", .where = "active = 1" });
    try testing.expectEqualStrings("SELECT * FROM users WHERE active = 1", w.buffered());
}
