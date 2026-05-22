# Plan: sharpen zql's dynamic-query value proposition

Cycle goal: tighten zql's public contract, safety messaging, and API correctness while doubling down on the advantage of composing SQL from Zig variables, optionals, slices, and enums.

## How to use

Pick the next unchecked task and create a focused branch for it.
Keep each task independently committable and verify it with `zig build test`.
Tick the task only after its branch is merged back to `main`.

## Phase 1 — Positioning and documentation

- [x] **docs(readme): clarify positioning and installation**

  Update `README.md` so zql is consistently described as a small dynamic SQL string builder rather than an ORM, driver, or safety layer. Fix the installation snippet to reference `github.com/erwagasore/zql` and the current `v0.0.1` tag. Anchor this to `SPEC.md:3` for purpose/positioning and `SPEC.md:39` for documentation requirements.

  *Done when:* the README tagline, installation section, and introductory value proposition match the spec and no longer mention placeholder repository/version values.

- [x] **docs(examples): demonstrate Zig-native dynamic composition**

  Rewrite key README examples to show zql benefiting from Zig variables, constants, optionals, slices, and enums instead of mostly static literal SQL fragments. Examples should emphasize reusable column lists, runtime filter flags, optional pagination, conditional `WHERE`, dynamic `SET` slices, and typed `Direction`, while still using placeholders for untrusted values. Anchor this to `SPEC.md:9` for target use cases and `SPEC.md:39` for documentation requirements.

  *Done when:* the primary examples make the library's advantage over raw SQL obvious through Zig-side composition, and `zig build test` still passes.

- [x] **docs(safety): make driver-bound placeholders the default pattern**

  Update `README.md` and `examples/README.md` so production examples lead with placeholder SQL and separate driver binding. Keep literal-inlining examples only where needed for demonstration, with explicit warnings. Anchor this to `SPEC.md:21` for safety boundaries and `SPEC.md:39` for documentation requirements.

  *Done when:* a reader copying the first examples would naturally write placeholder-based SQL rather than interpolating untrusted input.

## Phase 2 — API correctness

- [x] **feat(validation): reject structurally invalid statements**

  Extend `src/zql.zig` validation so modeled statements return explicit errors when required fields are missing, such as missing table names, missing INSERT columns/values, missing CREATE TABLE columns, missing CREATE INDEX names, or missing indexed columns. Update `zql.Error`, precise writer error sets, and inline tests. Anchor this to `SPEC.md:27` for correctness expectations.

  *Done when:* invalid modeled statements fail with documented errors, existing valid queries keep their output, and `zig build test` passes.

- [ ] **design(api): revisit value binding and dialect extension ergonomics**

  Reassess the API before changing helper names or adding dialect-specific clauses. Decide how zql should handle values near conditions, bind ordering, trusted literals versus user input, and dialect-specific features such as `RETURNING` without weakening the database-agnostic contract. Anchor this to `SPEC.md:21` for safety boundaries, `SPEC.md:27` for correctness expectations, and `SPEC.md:39` for documentation requirements.

  *Done when:* `docs/api-ergonomics.md` records the preferred direction and tradeoffs for value binding, literal helpers, and dialect extension points, with follow-up implementation tasks identified if needed.

## Phase 3 — Deferred dialect-specific expansion

- [ ] **docs(dialects): document why returning stays a raw SQL recipe**

  Keep `RETURNING` out of the core statement configs for now because it is not supported uniformly across SQL databases. Update the dialect-specific README section if needed so users understand when to append raw SQL and why this remains outside the database-agnostic core. Anchor this to `SPEC.md:1` for database-agnostic positioning and `SPEC.md:39` for documentation requirements.

  *Done when:* the docs clearly explain that `RETURNING` is available in PostgreSQL and modern SQLite but not universal, and no core `.returning` API is added.

## Ordering and parallelism

- `docs(readme): clarify positioning and installation` should land first because it establishes the public framing for the rest of the cycle.
- `docs(examples): demonstrate Zig-native dynamic composition` and `docs(safety): make driver-bound placeholders the default pattern` can proceed in parallel after the positioning update, but should be reconciled before merge to avoid conflicting README edits.
- `feat(validation): reject structurally invalid statements` can proceed independently of the documentation tasks and is already merged.
- `design(api): revisit value binding and dialect extension ergonomics` should happen before renaming literal helpers or adding any bound-query API.
- `docs(dialects): document why returning stays a raw SQL recipe` can happen after or alongside the API design note; it should not add a core `.returning` API.
