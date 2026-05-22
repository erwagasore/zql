# AGENTS — zql

Operating rules for humans + AI.

## 1. Project intent

zql is a small, zero-dependency SQL string builder for Zig. It assembles common
SQL statements from plain struct configs, optionals, slices, and enums. It is
not an ORM, not a driver, and not a safety layer.

## 2. Document precedence

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

## 3. Workflow

- Never commit to `main` for normal work.
- Always start on a new branch.
- Only push after the user approves.
- Merge via PR.

## 4. Commits

Use [Conventional Commits](https://www.conventionalcommits.org/).

- `fix` → patch
- `feat` → minor
- `feat!` / `BREAKING CHANGE` → major
- `chore`, `docs`, `refactor`, `test`, `ci`, `style`, `perf` → no version change

## 5. Releases

- Semantic versioning.
- Versions derived from Conventional Commits.
- Release performed locally via `/create-release` (no CI required).
- Manifest (`build.zig.zon`) is source of truth.
- Tags: `vX.Y.Z`

## 6. Repo map

| Path | Description |
|------|-------------|
| `src/zql.zig` | Single-file library — statements, helpers, aggregates, types, inline tests |
| `build.zig` | Build system — library module, test step |
| `build.zig.zon` | Package manifest (Zig 0.16.0) |
| `examples/` | Runnable httpz CRUD demo with isolated dependencies |
| `README.md` | Usage, examples, dialect-specific recipes |
| `SPEC.md` | Normative specification — purpose, API principles, safety boundaries |
| `AGENTS.md` | This file — operating rules, repo map, orientation |
| `docs/plan.md` | Active cycle checklist |
| `LICENSE` | MIT |
| `.gitignore` | Zig build artefacts |

## 7. Non-negotiables

1. **Zero dependencies** at the library level. No C bindings, no runtime deps.
2. **Dialect-neutral core.** zql never emits dialect-specific syntax.
3. **Driver handles binding.** zql builds SQL text; drivers bind values and execute.
4. **One allocation per statement.** `renderOwned` counts once, allocates once, writes once.
5. **Paired writer API.** Every allocator function has a `writeX` variant that streams to `std.Io.Writer`.
6. **Explicit allocator ownership.** Every `[]u8` result is caller-owned.

## 8. API principles

- Configuration via plain structs with defaults and optionals.
- `null` means "omit this clause" in statement configs.
- Helpers that inline values into SQL text must be clearly documented as "trusted literals only."
- Untrusted input must use driver placeholders (`?`, `$1`, etc.) bound separately.
- Validation errors (`NoTable`, `NoColumns`, etc.) are preferred over silently emitting invalid SQL.

## 9. Safety boundary

| Concern | Who owns it |
|---|---|
| SQL clause order | zql |
| Optional clauses / spacing | zql |
| Value escaping / binding | Driver |
| Placeholder syntax | User writes `?` or `$1` based on their driver |
| Static query readability | Raw SQL |

zql automates dynamic SQL shape assembly. It does not decide what is trusted.

## 10. Current state

- Core statements: SELECT, INSERT, INSERT MANY, UPDATE, DELETE, CREATE TABLE, DROP TABLE, CREATE INDEX
- Helpers: `eq`, `ne`, `gt`, `lt`, `ge`, `le`, `all`, `any`, `group`, `not`, `in`, `notIn`, `between`, `betweenDates`, `isNull`, `isNotNull`, `like`
- Aggregates: `sum`, `count`, `avg`, `min`, `max`, `coalesce`, `cast` (bare + aliased)
- Validation: `NoTable`, `NoColumns`, `NoValues`, `NoSetClauses`, `NoIndexName`, `ColsValuesMismatch`, `NoRows`
- Tests: inline tests for every statement and helper

## 11. Merge strategy

- Prefer squash merge.
- PR title must be a valid Conventional Commit.

## 12. Definition of done

- Works locally.
- `zig build test` passes.
- Tests updated if behaviour changed.
- README examples compile and reflect the actual API surface.
- No secrets committed.

## 13. Orientation

- **Entry point**: `src/zql.zig` — single-file library (~1000 lines, 60+ inline tests).
- **Domain**: SQL string builder for Zig. Dynamic query shape assembly from struct configs.
- **Stack**: Zig 0.16.x. Zero dependencies beyond `std`.
- **Current version**: 0.0.1.
