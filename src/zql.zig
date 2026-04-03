//! zql — A zero-dependency, database-agnostic SQL query builder for Zig.
//!
//! Memory contract: every function that returns a []const u8 allocates with
//! the provided allocator. The caller owns the result and must free it with
//! the same allocator.
//!
//! Example:
//!   const sql = try zql.select(allocator, .{ .table = "users", .limit = 50 });
//!   defer allocator.free(sql);

const std = @import("std");

// ── Shared types ──────────────────────────────────────────────────────────────

/// A key=value pair used in SET clauses (UPDATE) and WHERE helpers.
pub const KV = struct {
    key:   []const u8,
    value: []const u8,
};

/// Sort direction for ORDER BY.
pub const Direction = enum {
    asc,
    desc,

    fn toString(self: Direction) []const u8 {
        return switch (self) {
            .asc  => "ASC",
            .desc => "DESC",
        };
    }
};

/// A single ORDER BY term.
pub const OrderTerm = struct {
    col: []const u8,
    dir: Direction = .asc,
};

// ── SELECT ────────────────────────────────────────────────────────────────────

pub const SelectConfig = struct {
    /// Table to select from. Required.
    table:  []const u8          = "",
    /// Columns to select. Empty slice means SELECT *.
    cols:   []const []const u8  = &.{},
    /// Optional WHERE clause (raw SQL fragment, e.g. "active = 1").
    where:  ?[]const u8         = null,
    /// Optional ORDER BY terms.
    order:  []const OrderTerm   = &.{},
    /// Optional LIMIT.
    limit:  ?usize              = null,
    /// Optional OFFSET.
    offset: ?usize              = null,
    /// Optional JOIN clauses (raw SQL, e.g. "INNER JOIN orders ON ...").
    joins:  []const []const u8  = &.{},
    /// Optional GROUP BY columns.
    group:  []const []const u8  = &.{},
    /// Optional HAVING clause (raw SQL fragment).
    having: ?[]const u8         = null,
    /// If true, emits SELECT DISTINCT.
    distinct: bool              = false,
};

/// Builds a SELECT statement. Caller owns the returned slice.
pub fn select(allocator: std.mem.Allocator, config: SelectConfig) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("SELECT ");
    if (config.distinct) try buf.appendSlice("DISTINCT ");

    // Columns
    if (config.cols.len == 0) {
        try buf.append('*');
    } else {
        for (config.cols, 0..) |col, i| {
            if (i > 0) try buf.appendSlice(", ");
            try buf.appendSlice(col);
        }
    }

    // FROM
    try buf.appendSlice(" FROM ");
    try buf.appendSlice(config.table);

    // JOINs
    for (config.joins) |join| {
        try buf.append(' ');
        try buf.appendSlice(join);
    }

    // WHERE
    if (config.where) |w| {
        try buf.appendSlice(" WHERE ");
        try buf.appendSlice(w);
    }

    // GROUP BY
    if (config.group.len > 0) {
        try buf.appendSlice(" GROUP BY ");
        for (config.group, 0..) |col, i| {
            if (i > 0) try buf.appendSlice(", ");
            try buf.appendSlice(col);
        }
    }

    // HAVING
    if (config.having) |h| {
        try buf.appendSlice(" HAVING ");
        try buf.appendSlice(h);
    }

    // ORDER BY
    if (config.order.len > 0) {
        try buf.appendSlice(" ORDER BY ");
        for (config.order, 0..) |term, i| {
            if (i > 0) try buf.appendSlice(", ");
            try buf.appendSlice(term.col);
            try buf.append(' ');
            try buf.appendSlice(term.dir.toString());
        }
    }

    // LIMIT
    if (config.limit) |l| {
        const s = try std.fmt.allocPrint(allocator, " LIMIT {d}", .{l});
        defer allocator.free(s);
        try buf.appendSlice(s);
    }

    // OFFSET
    if (config.offset) |o| {
        const s = try std.fmt.allocPrint(allocator, " OFFSET {d}", .{o});
        defer allocator.free(s);
        try buf.appendSlice(s);
    }

    return buf.toOwnedSlice();
}

// ── INSERT ────────────────────────────────────────────────────────────────────

pub const InsertConfig = struct {
    /// Table to insert into. Required.
    table:  []const u8         = "",
    /// Column names. Must match values in length.
    cols:   []const []const u8 = &.{},
    /// Values as SQL literals (e.g. "'eugene'", "1", "NULL").
    values: []const []const u8 = &.{},
    /// If true, emits INSERT OR REPLACE (SQLite upsert).
    replace: bool              = false,
    /// If true, emits INSERT OR IGNORE (SQLite ignore on conflict).
    ignore:  bool              = false,
};

/// Builds an INSERT statement. Caller owns the returned slice.
pub fn insert(allocator: std.mem.Allocator, config: InsertConfig) ![]const u8 {
    if (config.cols.len != config.values.len) return error.ColsValuesMismatch;

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    if (config.replace) {
        try buf.appendSlice("INSERT OR REPLACE INTO ");
    } else if (config.ignore) {
        try buf.appendSlice("INSERT OR IGNORE INTO ");
    } else {
        try buf.appendSlice("INSERT INTO ");
    }

    try buf.appendSlice(config.table);

    // Columns
    try buf.appendSlice(" (");
    for (config.cols, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(", ");
        try buf.appendSlice(col);
    }
    try buf.append(')');

    // Values
    try buf.appendSlice(" VALUES (");
    for (config.values, 0..) |val, i| {
        if (i > 0) try buf.appendSlice(", ");
        try buf.appendSlice(val);
    }
    try buf.append(')');

    return buf.toOwnedSlice();
}

// ── INSERT MANY ───────────────────────────────────────────────────────────────

pub const InsertManyConfig = struct {
    /// Table to insert into. Required.
    table:   []const u8              = "",
    /// Column names. Required.
    cols:    []const []const u8      = &.{},
    /// Rows of values. Each row must match cols in length.
    rows:    []const []const []const u8 = &.{},
    /// If true, emits INSERT OR REPLACE.
    replace: bool                    = false,
    /// If true, emits INSERT OR IGNORE.
    ignore:  bool                    = false,
};

/// Builds a multi-row INSERT statement. Caller owns the returned slice.
pub fn insertMany(allocator: std.mem.Allocator, config: InsertManyConfig) ![]const u8 {
    if (config.rows.len == 0) return error.NoRows;
    for (config.rows) |row| {
        if (row.len != config.cols.len) return error.ColsValuesMismatch;
    }

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    if (config.replace) {
        try buf.appendSlice("INSERT OR REPLACE INTO ");
    } else if (config.ignore) {
        try buf.appendSlice("INSERT OR IGNORE INTO ");
    } else {
        try buf.appendSlice("INSERT INTO ");
    }

    try buf.appendSlice(config.table);

    // Columns
    try buf.appendSlice(" (");
    for (config.cols, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(", ");
        try buf.appendSlice(col);
    }
    try buf.appendSlice(") VALUES ");

    // Rows
    for (config.rows, 0..) |row, ri| {
        if (ri > 0) try buf.appendSlice(", ");
        try buf.append('(');
        for (row, 0..) |val, vi| {
            if (vi > 0) try buf.appendSlice(", ");
            try buf.appendSlice(val);
        }
        try buf.append(')');
    }

    return buf.toOwnedSlice();
}

// ── UPDATE ────────────────────────────────────────────────────────────────────

pub const UpdateConfig = struct {
    /// Table to update. Required.
    table: []const u8         = "",
    /// SET assignments as raw SQL fragments (e.g. "name = 'eugene'").
    set:   []const []const u8 = &.{},
    /// Optional WHERE clause. Omitting updates all rows.
    where: ?[]const u8        = null,
};

/// Builds an UPDATE statement. Caller owns the returned slice.
pub fn update(allocator: std.mem.Allocator, config: UpdateConfig) ![]const u8 {
    if (config.set.len == 0) return error.NoSetClauses;

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("UPDATE ");
    try buf.appendSlice(config.table);
    try buf.appendSlice(" SET ");

    for (config.set, 0..) |assignment, i| {
        if (i > 0) try buf.appendSlice(", ");
        try buf.appendSlice(assignment);
    }

    if (config.where) |w| {
        try buf.appendSlice(" WHERE ");
        try buf.appendSlice(w);
    }

    return buf.toOwnedSlice();
}

// ── DELETE ────────────────────────────────────────────────────────────────────

pub const DeleteConfig = struct {
    /// Table to delete from. Required.
    table: []const u8  = "",
    /// Optional WHERE clause. Omitting deletes all rows.
    where: ?[]const u8 = null,
};

/// Builds a DELETE statement. Caller owns the returned slice.
pub fn delete(allocator: std.mem.Allocator, config: DeleteConfig) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("DELETE FROM ");
    try buf.appendSlice(config.table);

    if (config.where) |w| {
        try buf.appendSlice(" WHERE ");
        try buf.appendSlice(w);
    }

    return buf.toOwnedSlice();
}

// ── CREATE TABLE ──────────────────────────────────────────────────────────────

pub const ColumnDef = struct {
    name:       []const u8,
    type:       []const u8,
    /// Optional constraints e.g. "NOT NULL", "PRIMARY KEY AUTOINCREMENT".
    constraints: []const u8 = "",
};

pub const CreateTableConfig = struct {
    /// Table name. Required.
    table:       []const u8       = "",
    /// Column definitions.
    cols:        []const ColumnDef = &.{},
    /// If true, emits CREATE TABLE IF NOT EXISTS.
    if_not_exists: bool           = false,
};

/// Builds a CREATE TABLE statement. Caller owns the returned slice.
pub fn createTable(allocator: std.mem.Allocator, config: CreateTableConfig) ![]const u8 {
    if (config.cols.len == 0) return error.NoColumns;

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    if (config.if_not_exists) {
        try buf.appendSlice("CREATE TABLE IF NOT EXISTS ");
    } else {
        try buf.appendSlice("CREATE TABLE ");
    }

    try buf.appendSlice(config.table);
    try buf.appendSlice(" (");

    for (config.cols, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(", ");
        try buf.appendSlice(col.name);
        try buf.append(' ');
        try buf.appendSlice(col.type);
        if (col.constraints.len > 0) {
            try buf.append(' ');
            try buf.appendSlice(col.constraints);
        }
    }

    try buf.append(')');

    return buf.toOwnedSlice();
}

// ── DROP TABLE ────────────────────────────────────────────────────────────────

pub const DropTableConfig = struct {
    /// Table name. Required.
    table:    []const u8 = "",
    /// If true, emits DROP TABLE IF EXISTS.
    if_exists: bool      = false,
};

/// Builds a DROP TABLE statement. Caller owns the returned slice.
pub fn dropTable(allocator: std.mem.Allocator, config: DropTableConfig) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    if (config.if_exists) {
        try buf.appendSlice("DROP TABLE IF EXISTS ");
    } else {
        try buf.appendSlice("DROP TABLE ");
    }

    try buf.appendSlice(config.table);

    return buf.toOwnedSlice();
}

// ── CREATE INDEX ──────────────────────────────────────────────────────────────

pub const CreateIndexConfig = struct {
    /// Index name. Required.
    name:         []const u8        = "",
    /// Table to index. Required.
    table:        []const u8        = "",
    /// Columns to index. Required.
    cols:         []const []const u8 = &.{},
    /// If true, emits CREATE UNIQUE INDEX.
    unique:       bool              = false,
    /// If true, emits CREATE INDEX IF NOT EXISTS.
    if_not_exists: bool             = false,
};

/// Builds a CREATE INDEX statement. Caller owns the returned slice.
pub fn createIndex(allocator: std.mem.Allocator, config: CreateIndexConfig) ![]const u8 {
    if (config.cols.len == 0) return error.NoColumns;

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("CREATE ");
    if (config.unique) try buf.appendSlice("UNIQUE ");
    try buf.appendSlice("INDEX ");
    if (config.if_not_exists) try buf.appendSlice("IF NOT EXISTS ");
    try buf.appendSlice(config.name);
    try buf.appendSlice(" ON ");
    try buf.appendSlice(config.table);
    try buf.appendSlice(" (");

    for (config.cols, 0..) |col, i| {
        if (i > 0) try buf.appendSlice(", ");
        try buf.appendSlice(col);
    }

    try buf.append(')');

    return buf.toOwnedSlice();
}

// ── WHERE helpers ─────────────────────────────────────────────────────────────
//
// Utilities for building WHERE clause strings before passing them
// to select/update/delete. All return caller-owned slices.

/// Joins conditions with AND.
///   where.all(allocator, &.{ "active = 1", "age > 18" })
///   → "active = 1 AND age > 18"
pub fn all(allocator: std.mem.Allocator, conditions: []const []const u8) ![]const u8 {
    return std.mem.join(allocator, " AND ", conditions);
}

/// Joins conditions with OR.
///   where.any(allocator, &.{ "role = 'admin'", "role = 'mod'" })
///   → "role = 'admin' OR role = 'mod'"
pub fn any(allocator: std.mem.Allocator, conditions: []const []const u8) ![]const u8 {
    return std.mem.join(allocator, " OR ", conditions);
}

/// Wraps a condition in parentheses.
///   where.group(allocator, "a = 1 OR b = 2")
///   → "(a = 1 OR b = 2)"
pub fn group(allocator: std.mem.Allocator, condition: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "({s})", .{condition});
}

/// Builds a NOT condition.
///   where.not(allocator, "active = 1")
///   → "NOT (active = 1)"
pub fn not(allocator: std.mem.Allocator, condition: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "NOT ({s})", .{condition});
}

/// Builds col IN (v1, v2, ...).
///   where.in(allocator, "id", &.{ "1", "2", "3" })
///   → "id IN (1, 2, 3)"
pub fn in(allocator: std.mem.Allocator, col: []const u8, values: []const []const u8) ![]const u8 {
    const joined = try std.mem.join(allocator, ", ", values);
    defer allocator.free(joined);
    return std.fmt.allocPrint(allocator, "{s} IN ({s})", .{ col, joined });
}

/// Builds col NOT IN (v1, v2, ...).
pub fn notIn(allocator: std.mem.Allocator, col: []const u8, values: []const []const u8) ![]const u8 {
    const joined = try std.mem.join(allocator, ", ", values);
    defer allocator.free(joined);
    return std.fmt.allocPrint(allocator, "{s} NOT IN ({s})", .{ col, joined });
}

/// Builds col BETWEEN low AND high.
pub fn between(allocator: std.mem.Allocator, col: []const u8, low: []const u8, high: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} BETWEEN {s} AND {s}", .{ col, low, high });
}

/// Builds col IS NULL.
pub fn isNull(allocator: std.mem.Allocator, col: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} IS NULL", .{col});
}

/// Builds col IS NOT NULL.
pub fn isNotNull(allocator: std.mem.Allocator, col: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} IS NOT NULL", .{col});
}

/// Builds col LIKE pattern.
pub fn like(allocator: std.mem.Allocator, col: []const u8, pattern: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} LIKE '{s}'", .{ col, pattern });
}

/// Builds col BETWEEN 'low' AND 'high' with quoted datetime strings.
///   zql.betweenDates(a, "created_at", "2026-03-01 00:00:00", "2026-04-01 00:00:00")
///   → "created_at BETWEEN '2026-03-01 00:00:00' AND '2026-04-01 00:00:00'"
pub fn betweenDates(
    allocator: std.mem.Allocator,
    col:       []const u8,
    from:      []const u8,
    to:        []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{s} BETWEEN '{s}' AND '{s}'",
        .{ col, from, to },
    );
}

// ── Aggregate functions ───────────────────────────────────────────────────────
//
// Two functions per aggregate: bare and aliased.
// Bare:    try zql.sum(a, "amount")            → "SUM(amount)"
// Aliased: try zql.sumAs(a, "amount", "total") → "SUM(amount) AS total"
// All return caller-owned slices.

// Internal helper — not exported.
fn agg(allocator: std.mem.Allocator, func: []const u8, col: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}({s})", .{ func, col });
}

fn aggAs(allocator: std.mem.Allocator, func: []const u8, col: []const u8, alias: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}({s}) AS {s}", .{ func, col, alias });
}

/// SUM(col)
///   try zql.sum(a, "amount") → "SUM(amount)"
pub fn sum(allocator: std.mem.Allocator, col: []const u8) ![]const u8 {
    return agg(allocator, "SUM", col);
}

/// SUM(col) AS alias
///   try zql.sumAs(a, "amount", "total") → "SUM(amount) AS total"
pub fn sumAs(allocator: std.mem.Allocator, col: []const u8, alias: []const u8) ![]const u8 {
    return aggAs(allocator, "SUM", col, alias);
}

/// COUNT(col) — pass "*" for COUNT(*)
///   try zql.count(a, "*") → "COUNT(*)"
pub fn count(allocator: std.mem.Allocator, col: []const u8) ![]const u8 {
    return agg(allocator, "COUNT", col);
}

/// COUNT(col) AS alias
///   try zql.countAs(a, "*", "total") → "COUNT(*) AS total"
pub fn countAs(allocator: std.mem.Allocator, col: []const u8, alias: []const u8) ![]const u8 {
    return aggAs(allocator, "COUNT", col, alias);
}

/// AVG(col)
///   try zql.avg(a, "price") → "AVG(price)"
pub fn avg(allocator: std.mem.Allocator, col: []const u8) ![]const u8 {
    return agg(allocator, "AVG", col);
}

/// AVG(col) AS alias
///   try zql.avgAs(a, "price", "avg_price") → "AVG(price) AS avg_price"
pub fn avgAs(allocator: std.mem.Allocator, col: []const u8, alias: []const u8) ![]const u8 {
    return aggAs(allocator, "AVG", col, alias);
}

/// MIN(col)
///   try zql.min(a, "price") → "MIN(price)"
pub fn min(allocator: std.mem.Allocator, col: []const u8) ![]const u8 {
    return agg(allocator, "MIN", col);
}

/// MIN(col) AS alias
///   try zql.minAs(a, "price", "min_price") → "MIN(price) AS min_price"
pub fn minAs(allocator: std.mem.Allocator, col: []const u8, alias: []const u8) ![]const u8 {
    return aggAs(allocator, "MIN", col, alias);
}

/// MAX(col)
///   try zql.max(a, "price") → "MAX(price)"
pub fn max(allocator: std.mem.Allocator, col: []const u8) ![]const u8 {
    return agg(allocator, "MAX", col);
}

/// MAX(col) AS alias
///   try zql.maxAs(a, "price", "max_price") → "MAX(price) AS max_price"
pub fn maxAs(allocator: std.mem.Allocator, col: []const u8, alias: []const u8) ![]const u8 {
    return aggAs(allocator, "MAX", col, alias);
}

/// COALESCE(col, fallback)
///   try zql.coalesce(a, "nickname", "'anonymous'") → "COALESCE(nickname, 'anonymous')"
pub fn coalesce(allocator: std.mem.Allocator, col: []const u8, fallback: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "COALESCE({s}, {s})", .{ col, fallback });
}

/// COALESCE(col, fallback) AS alias
///   try zql.coalesceAs(a, "nickname", "'anonymous'", "display_name")
///   → "COALESCE(nickname, 'anonymous') AS display_name"
pub fn coalesceAs(allocator: std.mem.Allocator, col: []const u8, fallback: []const u8, alias: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "COALESCE({s}, {s}) AS {s}", .{ col, fallback, alias });
}

/// CAST(col AS type)
///   try zql.cast(a, "price", "INTEGER") → "CAST(price AS INTEGER)"
pub fn cast(allocator: std.mem.Allocator, col: []const u8, as_type: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "CAST({s} AS {s})", .{ col, as_type });
}

/// CAST(col AS type) AS alias
///   try zql.castAs(a, "price", "INTEGER", "int_price") → "CAST(price AS INTEGER) AS int_price"
pub fn castAs(allocator: std.mem.Allocator, col: []const u8, as_type: []const u8, alias: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "CAST({s} AS {s}) AS {s}", .{ col, as_type, alias });
}
