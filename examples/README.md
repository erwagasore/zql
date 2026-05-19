# zql + httpz example

A small `users` CRUD service demonstrating how zql is meant to be used inside
an HTTP handler against `req.arena`.

There is no database. Each handler returns the SQL that zql built — `curl` the
endpoints to see exactly what the library produces for each input.

## Run

```bash
zig build run
```

Then in another shell:

```bash
curl 'http://localhost:5882/users?active=1&limit=10'
curl  http://localhost:5882/users/42
curl -XPOST http://localhost:5882/users \
     -H 'content-type: application/json' \
     -d '{"name":"Eugene","email":"e@p.io","active":true}'
curl -XPATCH http://localhost:5882/users/42 \
     -H 'content-type: application/json' \
     -d '{"active":false}'
curl -XDELETE http://localhost:5882/users/42
curl  http://localhost:5882/users/stats
```

Example response:

```json
{ "sql": "INSERT INTO users (name, email, active) VALUES ('Eugene', 'e@p.io', 1)" }
```

## Routes

| Method | Path           | zql feature exercised                                |
|--------|----------------|------------------------------------------------------|
| GET    | `/users`       | Conditional `WHERE` via `null`-or-value; typed `LIMIT`/`OFFSET`; `ORDER BY` |
| GET    | `/users/stats` | Aggregate (`countAs`) + `GROUP BY` + `ORDER BY`      |
| GET    | `/users/:id`   | Composed `WHERE` from a route param                  |
| POST   | `/users`       | Dialect-neutral `INSERT` with SQL `NULL` default     |
| PATCH  | `/users/:id`   | Dynamic SET list assembled from a small `ArrayList`  |
| DELETE | `/users/:id`   | `DELETE` with composed predicate                     |

## ⚠️ For demonstration only

These handlers inline route and body string values directly into the SQL
(e.g. `id = '42'`) so the response shows complete, runnable statements.
**Do not copy this pattern to production code** — it is vulnerable to SQL
injection.

Real handlers should emit placeholder SQL using their driver's convention
(`?` for SQLite/MySQL, `$1` for Postgres) and pass values separately to the
driver's bind/exec call. zql renders the SQL string; the driver layer
handles value binding. That handoff is intentionally outside zql's scope.

## Project layout

```
examples/
├── build.zig            # builds the example exe
├── build.zig.zon        # declares httpz dep + zql via local path
├── README.md            # (this file)
└── src/
    └── web.zig          # handler implementations
```

The example is isolated from the main library — depending on zql from
elsewhere does **not** transitively pull in httpz.

## Back to main

See [../README.md](../README.md) for full zql documentation, including the
[Dialect-specific features](../README.md#dialect-specific-features-use-raw-sql)
section that lists what zql intentionally doesn't model and how to do those
things with raw SQL.
