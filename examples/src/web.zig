//! zql + httpz — users CRUD example.
//!
//! Each handler builds SQL with `zql` against `req.arena` and returns the
//! result as JSON so you can `curl` the endpoints and see exactly what zql
//! produces. There is no database — that keeps the example focused on
//! query construction and the allocator pattern.
//!
//! ─────────────────────────────────────────────────────────────────────────
//! ⚠️  FOR DEMONSTRATION ONLY
//!
//! Route and body string values are inlined directly into the SQL here
//! (e.g. `id = '42'`) so the response shows complete, runnable statements.
//! DO NOT copy this pattern to production code — it is vulnerable to SQL
//! injection.
//!
//! In real handlers, build the SQL with placeholder syntax appropriate to
//! your driver (`?` for SQLite/MySQL, `$1` for Postgres) and pass values
//! separately to the driver's bind/exec call. zql renders the SQL string;
//! your driver binds the values.
//! ─────────────────────────────────────────────────────────────────────────
//!
//! Run:   zig build run
//! Try:   curl 'http://localhost:5882/users?active=1&limit=10'
//!        curl  http://localhost:5882/users/42
//!        curl -XPOST http://localhost:5882/users \
//!             -H 'content-type: application/json' \
//!             -d '{"name":"Eugene","email":"e@p.io","active":true}'
//!        curl -XPATCH http://localhost:5882/users/42 \
//!             -H 'content-type: application/json' -d '{"active":false}'
//!        curl -XDELETE http://localhost:5882/users/42
//!        curl  http://localhost:5882/users/stats

const std   = @import("std");
const httpz = @import("httpz");
const zql   = @import("zql");

pub fn main(init: std.process.Init) !void {
    var server = try httpz.Server(void).init(init.io, init.gpa, .{
        .address = .localhost(5882),
    }, {});
    defer {
        server.stop();
        server.deinit();
    }

    var router = try server.router(.{});
    router.get   ("/users",        listUsers,  .{});
    router.get   ("/users/stats",  userStats,  .{});
    router.get   ("/users/:id",    getUser,    .{});
    router.post  ("/users",        createUser, .{});
    router.patch ("/users/:id",    updateUser, .{});
    router.delete("/users/:id",    deleteUser, .{});

    std.debug.print("zql web example listening on http://localhost:5882\n", .{});
    try server.listen();
}

const USER_COLS = &.{ "id", "name", "email", "active", "created_at" };

// ── GET /users?active=1&limit=N&offset=N ──────────────────────────────────────
// Conditional WHERE / LIMIT / OFFSET via `null`-or-value, plus ORDER BY.

fn listUsers(req: *httpz.Request, res: *httpz.Response) !void {
    const q = try req.query();

    const sql = try zql.select(req.arena, .{
        .table  = "users",
        .cols   = USER_COLS,
        .where  = if (q.get("active") != null) "active = 1" else null,
        .order  = &.{.{ .col = "created_at", .dir = .desc }},
        .limit  = try parseOpt(q.get("limit")),
        .offset = try parseOpt(q.get("offset")),
    });

    try res.json(.{ .sql = sql }, .{});
}

// ── GET /users/:id ────────────────────────────────────────────────────────────

fn getUser(req: *httpz.Request, res: *httpz.Response) !void {
    const id    = req.param("id").?;
    const where = try std.fmt.allocPrint(req.arena, "id = '{s}'", .{id});

    const sql = try zql.select(req.arena, .{
        .table = "users",
        .cols  = USER_COLS,
        .where = where,
        .limit = 1,
    });

    try res.json(.{ .sql = sql }, .{});
}

// ── POST /users ───────────────────────────────────────────────────────────────
// zql's dialect-neutral INSERT, with `active` defaulting to SQL NULL when
// omitted (no ArrayList needed).

const NewUser = struct {
    name:   []const u8,
    email:  []const u8,
    active: ?bool = null,
};

fn createUser(req: *httpz.Request, res: *httpz.Response) !void {
    const new = (try req.json(NewUser)) orelse {
        res.status = 400;
        return;
    };

    const name_lit  = try std.fmt.allocPrint(req.arena, "'{s}'", .{new.name});
    const email_lit = try std.fmt.allocPrint(req.arena, "'{s}'", .{new.email});
    const active_lit: []const u8 = if (new.active) |a|
        (if (a) "1" else "0")
    else
        "NULL";

    const sql = try zql.insert(req.arena, .{
        .table  = "users",
        .cols   = &.{ "name", "email", "active" },
        .values = &.{ name_lit, email_lit, active_lit },
    });

    res.status = 201;
    try res.json(.{ .sql = sql }, .{});
}

// ── PATCH /users/:id ──────────────────────────────────────────────────────────
// Dynamic SET list — only the fields the caller sent. This is the case
// where building a small std.ArrayList is unavoidable; zql consumes
// `.items` directly so there's no second copy.

const PatchUser = struct {
    name:   ?[]const u8 = null,
    email:  ?[]const u8 = null,
    active: ?bool       = null,
};

fn updateUser(req: *httpz.Request, res: *httpz.Response) !void {
    const a     = req.arena;
    const id    = req.param("id").?;
    const patch = (try req.json(PatchUser)) orelse {
        res.status = 400;
        return;
    };

    var sets: std.ArrayList([]const u8) = .empty;
    defer sets.deinit(a);

    if (patch.name)   |v| try sets.append(a,
        try std.fmt.allocPrint(a, "name = '{s}'",  .{v}));
    if (patch.email)  |v| try sets.append(a,
        try std.fmt.allocPrint(a, "email = '{s}'", .{v}));
    if (patch.active) |v| try sets.append(a,
        if (v) "active = 1" else "active = 0");

    if (sets.items.len == 0) {
        res.status = 400;
        return;
    }

    const where = try std.fmt.allocPrint(a, "id = '{s}'", .{id});

    const sql = try zql.update(a, .{
        .table = "users",
        .set   = sets.items,
        .where = where,
    });

    try res.json(.{ .sql = sql }, .{});
}

// ── DELETE /users/:id ─────────────────────────────────────────────────────────

fn deleteUser(req: *httpz.Request, res: *httpz.Response) !void {
    const id    = req.param("id").?;
    const where = try std.fmt.allocPrint(req.arena, "id = '{s}'", .{id});

    const sql = try zql.delete(req.arena, .{
        .table = "users",
        .where = where,
    });

    try res.json(.{ .sql = sql }, .{});
}

// ── GET /users/stats ──────────────────────────────────────────────────────────
// Aggregate with alias, GROUP BY, composed inline with the arena.

fn userStats(req: *httpz.Request, res: *httpz.Response) !void {
    const a = req.arena;

    const sql = try zql.select(a, .{
        .table = "users",
        .cols  = &.{
            "active",
            try zql.countAs(a, "*", "n"),
        },
        .group = &.{"active"},
        .order = &.{.{ .col = "active", .dir = .asc }},
    });

    try res.json(.{ .sql = sql }, .{});
}

// ── helpers ───────────────────────────────────────────────────────────────────

fn parseOpt(s: ?[]const u8) !?usize {
    if (s) |str| return try std.fmt.parseInt(usize, str, 10);
    return null;
}
