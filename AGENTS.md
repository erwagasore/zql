# AGENTS — zql

Operational guidance for contributors and coding agents.

## 1) Project intent

zql is a small, zero-dependency SQL string builder for Zig. It assembles common
SQL statements from plain struct configs, optionals, slices, and enums. It is
not an ORM, not a driver, and not a safety layer.

## 2) Document precedence

Normative sources for behavior:
1. `SPEC.md`
2. `AGENTS.md`

Companion docs:
- `README.md` — user-facing usage and examples
- `docs/plan.md` — transient cycle checklist (lives until promoted)

When changing behavior, keep docs synchronized in this order:
1. `SPEC.md`
2. `AGENTS.md`
3. `README.md`
4. `docs/plan.md`

## 3) Non-negotiables

1. **Zero dependencies** at the library level. No C bindings, no runtime deps.
2. **Dialect-neutral core.** zql never emits dialect-specific syntax.
3. **Driver handles binding.** zql builds SQL text; drivers bind values and execute.
4. **One allocation per statement.** `renderOwned` counts once, allocates once, writes once.
5. **Paired writer API.** Every allocator function has a `writeX` variant that streams to `std.Io.Writer`.
6. **Explicit allocator ownership.** Every `[]u8` result is caller-owned.

## 4) API principles

- Configuration via plain structs with defaults and optionals.
- `null` means "omit this clause" in statement configs.
- Helpers that inline values into SQL text must be clearly documented as "trusted literals only."
- Untrusted input must use driver placeholders (`?`, `$1`, etc.) bound separately.
- Validation errors (`NoTable`, `NoColumns`, etc.) are preferred over silently emitting invalid SQL.

## 5) Safety boundary

| Concern | Who owns it |
|---|---|
| SQL clause order | zql |
| Optional clauses / spacing | zql |
| Value escaping / binding | Driver |
| Placeholder syntax | User writes `?` or `$1` based on their driver |
| Static query readability | Raw SQL |

zql automates dynamic SQL shape assembly. It does not decide what is trusted.

## 6) Current state

- Core statements: SELECT, INSERT, INSERT MANY, UPDATE, DELETE, CREATE TABLE, DROP TABLE, CREATE INDEX
- Helpers: `eq`, `ne`, `gt`, `lt`, `ge`, `le`, `all`, `any`, `group`, `not`, `in`, `notIn`, `between`, `betweenDates`, `isNull`, `isNotNull`, `like`
- Aggregates: `sum`, `count`, `avg`, `min`, `max`, `coalesce`, `cast` (bare + aliased)
- Validation: `NoTable`, `NoColumns`, `NoValues`, `NoSetClauses`, `NoIndexName`, `ColsValuesMismatch`, `NoRows`
- Tests: inline tests for every statement and helper

## 7) What's next

- Complete `docs(dialects): document why RETURNING stays a raw SQL recipe`
- Consider helper renames for clarity (`betweenDates` → `literalBetween` or similar)
- Evaluate whether `like` / `betweenDates` doc warnings are sufficient or if names should change
- Add CI for `zig build test` when GitHub Actions is acceptable

## 8) Acceptance checks

- `zig build test` passes on supported Zig version.
- No uncommitted changes before PR creation.
- Every PR is independently committable and passes tests.
- README examples compile and reflect the actual API surface.
