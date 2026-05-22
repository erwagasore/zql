# zql Specification

## 1. Purpose and positioning

zql is a small, zero-dependency SQL string builder for Zig. It exists to make common dynamic SQL construction less error-prone while preserving Zig's explicit style and leaving database execution, value binding, escaping, result mapping, migrations, and connection management to database drivers or application code.

zql is not an ORM, not a database driver, and not a SQL-injection safety layer. Its core value is assembling structurally correct SQL strings from plain Zig config structs and raw SQL fragments.

## 2. Target users and use cases

zql targets Zig applications that already use a database driver and want lightweight help building SQL strings, especially for optional filters, pagination, ordering, CRUD statements, simple DDL, aggregate expressions, and composed WHERE fragments.

Raw SQL remains preferred for fixed, static queries. zql is most useful when the query shape is conditional or assembled from reusable fragments.

## 3. API principles

The public API should remain small, explicit, and idiomatic Zig. Configuration is expressed with plain structs, slices, optionals, enums, and caller-provided allocators. Every allocated result is caller-owned and must be freed with the allocator that produced it.

Every statement-level allocator function should have a paired writer function that writes to `std.Io.Writer`, allowing callers to avoid intermediate allocations when they already have a writer.

## 4. Safety boundaries

zql emits SQL text exactly from the identifiers, fragments, and values supplied by the caller. It must document that untrusted input should be represented by driver placeholders and bound separately by the database driver.

Helpers that quote or inline literal values must be named and documented so their injection risk is obvious. The library should not imply that it escapes, sanitizes, or binds user input.

## 5. Correctness expectations

zql should guarantee the structural SQL ordering it models, such as SELECT clause order, JOIN before WHERE, WHERE before GROUP BY, GROUP BY before HAVING, HAVING before ORDER BY, and LIMIT before OFFSET.

Where a modeled statement cannot produce valid SQL without required fields, zql should return explicit validation errors rather than silently emitting invalid SQL. Examples include missing table names, empty INSERT columns or values, empty CREATE TABLE columns, and missing CREATE INDEX names.

## 6. Memory and performance contract

Statement-level allocator functions should render with exactly one final allocation sized to the output, using the paired writer implementation as the source of truth. Writer functions should stream directly to the supplied writer and should not allocate.

Small fragment helpers may allocate when their return type is an owned `[]u8`, but their ownership and allocation behavior must be documented.

## 7. Documentation requirements

The README should clearly present zql as a dynamic SQL string builder, explain when raw SQL is preferable, and show production-safe placeholder-based examples. Installation instructions must reference the actual repository and current release tags.

Examples may inline literals only for demonstration if they prominently warn that production code must bind values through the database driver.

## 8. Quality bar

The library must build and pass tests on the supported Zig version. The repository should include CI for `zig build test`, inline tests for each modeled statement and helper, and regression tests for validation errors and safety-sensitive documentation examples.

The package should remain dependency-free at the library level. Optional examples may have isolated dependencies that do not leak into downstream users.
