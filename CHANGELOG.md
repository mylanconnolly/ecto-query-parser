# Changelog

## v0.3.0

### Added

- **`has_many` and `many_to_many` relationship support.** Plural-side filters
  now compile to correlated `EXISTS` subqueries instead of `LEFT JOIN`s,
  avoiding the row-duplication that previously corrupted counts and
  `ORDER BY` / `LIMIT` on schema-based has-many filters.
- New schemaless `allowed_fields` tuple shapes peer with the existing
  `{:assoc, ...}`:
  - `{:belongs_to, table:, owner_key:, related_key:, fields:, prefix:}` —
    alias for `{:assoc, ...}`.
  - `{:has_many, table:, owner_key:, related_key:, fields:, prefix:}` —
    emits `EXISTS (SELECT 1 FROM table WHERE related_key = parent.owner_key …)`.
  - `{:many_to_many, table:, join_through:, join_owner_key:,
     join_related_key:, owner_key:, related_key:, fields:, prefix:,
     join_prefix:}` — emits `EXISTS` through the join table.
- Schema-mode association cardinality is auto-detected from
  `__schema__(:association, name)`. `belongs_to` and `has_one` keep
  producing `LEFT JOIN`; `has_many` and `many_to_many` switch to `EXISTS`.
- §4-style grouping: when multiple predicates filter the same plural alias
  under the same boolean connector, they collapse into one `EXISTS`. AND
  on `comments.body` and `comments.spam` produces a single subquery whose
  WHERE clause combines both predicates; OR similarly OR-s them inside one
  `EXISTS`. Predicates on different aliases stay in separate `EXISTS`
  clauses.
- `:prefix` option on `belongs_to`, `has_many`, and `many_to_many` tuples
  (also `:join_prefix` on `many_to_many`) flows through to the
  `LEFT JOIN` source or `EXISTS` subquery's `FROM` / `JOIN`. This
  eliminates the need for downstream `JoinExpr.prefix` patching when
  using schema prefixes for multi-tenancy.

### Changed

- **Schema-mode `has_many` filtering** previously emitted a `LEFT JOIN`
  that silently duplicated parent rows for each match. It now emits an
  `EXISTS` subquery and never duplicates. This is a deliberate fix; users
  who were applying `DISTINCT` externally to compensate can remove it.
- `EctoQueryParser.apply/3` now normalizes the queryable to an
  `%Ecto.Query{}` and names the source binding (`as: :__eqp_source`) if
  the user hasn't named it. This lets the EXISTS subquery's `parent_as`
  correlation reference the outer source. A user-supplied `as:` on the
  source is preserved.

### Limitations (v1)

- Plural associations must be the **first segment** of a dotted path:
  `comments.author.name` works, but `author.comments.body` returns an
  error. This restriction may be lifted in a follow-up.
- `NOT EXISTS` filters ("posts with no comments") are not yet supported
  — they require parser-level negation, which is a separate change.

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
