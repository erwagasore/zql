# Plan: sharpen zql's dynamic-query value proposition

Cycle goal: tighten zql's public contract, safety messaging, and API correctness while doubling down on the advantage of composing SQL from Zig variables, optionals, slices, and enums.

## How to use

Pick the next unchecked task and create a focused branch for it.
Keep each task independently committable and verify it with `zig build test`.
Tick the task only after its branch is merged back to `main`.

## Phase 1 — Positioning and documentation

- [ ] **docs(readme): clarify positioning and installation**

  Update `README.md` so zql is consistently described as a small dynamic SQL string builder rather than an ORM, driver, or safety layer. Fix the installation snippet to reference `github.com/erwagasore/zql` and the current `v0.0.1` tag. Anchor this to `SPEC.md:3` for purpose/positioning and `SPEC.md:39` for documentation requirements.

  *Done when:* the README tagline, installation section, and introductory value proposition match the spec and no longer mention placeholder repository/version values.

- [ ] **docs(examples): demonstrate Zig-native dynamic composition**

  Rewrite key README examples to show zql benefiting from Zig variables, constants, optionals, slices, and enums instead of mostly static literal SQL fragments. Examples should emphasize reusable column lists, runtime filter flags, optional pagination, conditional `WHERE`, dynamic `SET` slices, and typed `Direction`, while still using placeholders for untrusted values. Anchor this to `SPEC.md:9` for target use cases and `SPEC.md:39` for documentation requirements.

  *Done when:* the primary examples make the library's advantage over raw SQL obvious through Zig-side composition, and `zig build test` still passes.

- [ ] **docs(safety): make driver-bound placeholders the default pattern**

  Update `README.md` and `examples/README.md` so production examples lead with placeholder SQL and separate driver binding. Keep literal-inlining examples only where needed for demonstration, with explicit warnings. Anchor this to `SPEC.md:21` for safety boundaries and `SPEC.md:39` for documentation requirements.

  *Done when:* a reader copying the first examples would naturally write placeholder-based SQL rather than interpolating untrusted input.

## Phase 2 — API correctness

- [ ] **feat(validation): reject structurally invalid statements**

  Extend `src/zql.zig` validation so modeled statements return explicit errors when required fields are missing, such as missing table names, missing INSERT columns/values, missing CREATE TABLE columns, missing CREATE INDEX names, or missing indexed columns. Update `zql.Error`, precise writer error sets, and inline tests. Anchor this to `SPEC.md:27` for correctness expectations.

  *Done when:* invalid modeled statements fail with documented errors, existing valid queries keep their output, and `zig build test` passes.

- [ ] **refactor(helpers): make literal-inlining helpers explicit**

  Review helpers such as `like` and `betweenDates` in `src/zql.zig` and the README. Rename, deprecate, or document them so it is unmistakable that they inline literal values and do not escape input. Prefer helper examples that compose placeholder fragments when values may be untrusted. Anchor this to `SPEC.md:21` for safety boundaries.

  *Done when:* literal-inlining helpers are clearly named or documented, tests cover the final names/behavior, and safety messaging is consistent across docs.

## Phase 3 — Small dialect-neutral API expansion

- [ ] **feat(statements): add generic returning support**

  Add an optional `returning` field to statements where a suffix can remain simple and dialect-neutral, likely `InsertConfig`, `UpdateConfig`, and `DeleteConfig`. Keep it as raw SQL column/expression slices or a string fragment rather than modeling dialect-specific behavior. Anchor this to `SPEC.md:9` for common use cases and `SPEC.md:27` for structural correctness.

  *Done when:* `RETURNING` can be appended without manual string concatenation, tests cover insert/update/delete returning clauses, and unsupported dialect caveats are documented.

## Ordering and parallelism

- `docs(readme): clarify positioning and installation` should land first because it establishes the public framing for the rest of the cycle.
- `docs(examples): demonstrate Zig-native dynamic composition` and `docs(safety): make driver-bound placeholders the default pattern` can proceed in parallel after the positioning update, but should be reconciled before merge to avoid conflicting README edits.
- `feat(validation): reject structurally invalid statements` can proceed independently of the documentation tasks, but should land before `feat(statements): add generic returning support` so new fields follow the final validation/error style.
- `refactor(helpers): make literal-inlining helpers explicit` can proceed after or alongside the safety docs, but its final names/docs must be reflected in README examples.
- `feat(statements): add generic returning support` depends on validation/error conventions and should be the last API-changing task in this cycle.
