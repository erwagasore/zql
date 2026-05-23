# Plan: improve API predictability, memory ergonomics, build tooling, and test coverage

Cycle goal: make helper quoting consistent, document memory patterns, add build convenience, close test gaps, and add a common aggregate variant.

## How to use

Pick the next unchecked task and create a focused branch for it.
Keep each task independently committable and verify it with `zig build test`.
Tick the task only after its branch is merged back to `main`.

## Tasks

- [x] **docs(memory): document arena allocator pattern for compositions**

  Add a README section explaining that complex WHERE compositions create intermediate allocations per helper call, and that `std.heap.ArenaAllocator` is the recommended pattern for batching them. Anchor this to `SPEC.md:149` for the memory contract and `SPEC.md:159` for documentation requirements.

  *Done when:* README includes an explicit arena example for multi-fragment WHERE composition and `zig build test` passes.

- [x] **refactor(helpers): remove automatic quoting from `like` and `betweenDates`**

  Make all helpers consistent: none quote values. `like` and `betweenDates` currently wrap args in `'`, but `eq`, `between`, `coalesce`, etc. do not. Remove the automatic quoting so callers always control literal formatting. Update inline tests, README examples, and SPEC API surface table accordingly. Anchor this to `SPEC.md:20` for API surface and `SPEC.md:115` for safety boundaries.

  *Done when:* `like` and `betweenDates` no longer quote values, all tests and docs reflect the change, and `zig build test` passes.

- [x] **feat(build): add `check` step and restrict package manifest paths**

  Add a `check` step to `build.zig` for fast compilation checking. Restrict `build.zig.zon` `.paths` to `src`, `build.zig`, `build.zig.zon`, `LICENSE`, and `README.md` to avoid publishing non-library files. Anchor this to `SPEC.md:171` for the quality bar.

  *Done when:* `zig build check` works and `build.zig.zon` paths are restricted.

- [ ] **test(coverage): add missing edge case tests**

  Add tests for: multiple `joins`, `offset` without `limit`, mixed `order` directions, `distinct` with explicit columns, `writeInsertMany` via fixed buffer, and `update`/`delete` writer variants. Anchor this to `SPEC.md:171` for the quality bar.

  *Done when:* new tests cover the listed gaps and `zig build test` passes.

- [ ] **feat(aggregates): add `distinct` variant for `count`**

  Add `countDistinct` and `countDistinctAs` helpers for `COUNT(DISTINCT col)`. This is common SQL that currently requires passing `"DISTINCT id"` as a raw column name to `count()`. Anchor this to `SPEC.md:20` for the API surface.

  *Done when:* `countDistinct` and `countDistinctAs` exist with tests, and `zig build test` passes.

## Ordering and parallelism

- `docs(memory)` and `feat(build)` can proceed in parallel — they touch different files.
- `refactor(helpers)` should land before `test(coverage)` so new tests use the consistent quoting behavior.
- `feat(aggregates)` can proceed independently at any time.
- All tasks can ship in any order after `refactor(helpers)` completes.
