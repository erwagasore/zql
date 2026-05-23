# Changelog

## [0.1.0] — 2026-05-22

### Features
- Reject structurally invalid statements with explicit validation errors
- Add eq, ne, gt, lt, ge, le comparison helpers
- Add countDistinct and countDistinctAs aggregate helpers
- Add `zig build check` step and restrict package manifest paths

### Refactors
- Remove automatic quoting from like and betweenDates for consistent caller-controlled literal formatting

### Tests
- Add missing edge case tests for multiple joins, offset without limit, distinct multi-column, and writer API variants

### Documentation
- Clarify zql positioning and safety model
- Add concrete with/without zql comparison
- Add AGENTS.md with standard template
- Document arena allocator pattern for complex WHERE compositions

## [0.0.1] — 2025-05-13

### Features
- Initial release: SELECT, INSERT, INSERT MANY, UPDATE, DELETE, CREATE TABLE, DROP TABLE, CREATE INDEX
- Aggregate helpers: sum, count, avg, min, max, coalesce, cast
- WHERE fragment helpers: all, any, group, not, in, notIn, between, betweenDates, isNull, isNotNull, like
- Writer API for all statements (zero-intermediate-allocation streaming)
- Single-allocation renderer pattern via renderOwned
