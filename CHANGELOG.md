# Changelog

## v0.2.0

- Automatic literal type coercion in comparisons. When a literal is compared
  against a typed field (e.g., `performed_on >= "2026-05-20"` where
  `performed_on` is a `:date`), the literal is now wrapped with `type/2` so
  Ecto and the database driver cast it to the column's type. Previously this
  could fail in PostgreSQL with errors like `operator does not exist: date >= text`.
- Coercion sources its type information from the schema (`__schema__(:type, _)`),
  from the keyword form of `:allowed_fields`, and by walking association paths
  to the leaf field. Works for `==`, `!=`, `>=`, `<=`, and `includes` in both
  operand orders.
- Coercion is skipped when the literal's natural type already matches the field
  (e.g., string-vs-string, integer-vs-integer), so existing queries are not
  affected.

## v0.1.0

- Initial release
- Query language parser with support for strings, integers, floats, booleans, and lists
- Comparison operators: `==`, `!=`, `>=`, `<=`
- Text operators: `contains`, `like`, `ilike`, `search`
- Array operator: `includes`
- Logical operators: `AND`, `OR`, parenthesized grouping
- String functions: `UPPER`, `LOWER`, `TRIM`, `LENGTH`, `LEFT`, `RIGHT`, `SUBSTRING`, `CONCAT`, `REPLACE`, `COALESCE`
- Math functions: `ABS`, `FLOOR`, `CEIL`
- Date/time functions: `NOW()`, `ROUND_SECOND` through `ROUND_YEAR`, `ADD_INTERVAL`, `SUB_INTERVAL`
- Automatic left joins for dotted association paths (e.g., `author.name`)
- JSONB column access for `:map` fields (e.g., `metadata.key`)
- Schemaless query support with association definitions in `allowed_fields`
- Field allowlisting via `:allowed_fields` option
