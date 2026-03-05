# Changelog

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
