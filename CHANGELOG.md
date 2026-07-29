# Changelog

## v0.5.1

### Fixed

- **Table names may contain hyphens.** A pipe source segment previously had to
  be a bare unquoted SQL identifier, so a schema-per-tenant layout that names
  schemas after UUIDs — `client_559de6a3-0cc8-4813-a9be-9c31a39ab47d.controls`
  — failed to parse at the first hyphen. Table references only ever appear in
  the source position, where there is no arithmetic for a `-` to belong to, so
  hyphens are unambiguous there. A source must still *start* like an
  identifier, and aliases, column paths, and function names are unchanged.

## v0.5.0

One release, two headline features: `{{name}}` **parameters** (with
`[[optional]]` groups and the `literal_transform:` hook) for the existing
filter API, and the full **pipe language** — the staged query language from
`docs/pipe-language.md` (source + `filter`/`select`/`group`/`sort`/`limit`/
`offset` stages, staged compilation, `@slug` external references, positioned
validation errors). The pipe language was originally slated for v0.6.0 and
was folded into this unpublished release instead of shipping two releases in
one day.

### Added — the pipe language

- **`EctoQueryParser.parse_pipe/1` and `EctoQueryParser.build_pipe/2`** —
  parse and compile staged pipe queries:

  ```
  orders
  | filter status == "paid" AND created_at >= "last month"
  | group customer.region { total = sum(amount), n = count() }
  | sort -total
  | limit 10
  ```

  A query is a source plus `|`-separated stages (whitespace/newlines around
  `|` insignificant; a bare source is valid). `parse_pipe/1` returns an
  `%EctoQueryParser.Pipe.Query{}` exposing the `:source` so callers can
  validate the referenced table against their catalog before building;
  `build_pipe/2` accepts the text or the parsed struct plus the existing
  `allowed_fields:` / `params:` / `literal_transform:` options and the new
  `resolve_source:`.
- **Stages.**
  - `filter <expr>` — the existing filter grammar verbatim (operators,
    functions, association paths with JOIN/EXISTS, JSONB paths, `{{params}}`,
    `[[optional]]` groups). Multiple filter stages allowed.
  - `select col [, col ...]` — identifiers (association paths,
    singular-only) or `alias = FUNC(...)` with the existing function set;
    restricts the output shape for later stages.
  - `group [breakouts] { alias = agg(...), ... }` — breakouts are
    identifiers, function applications (`ROUND_*` temporal bucketing), or
    `alias = FUNC(...)`; un-aliased function breakouts get a derived,
    referenceable name (`round_month_created_at`). Aggregations: `count()`,
    `count(col)`, `count_distinct(col)`, `sum(col)`, `avg(col)`, `min(col)`,
    `max(col)` — every aggregation aliased, aliases must not collide with
    each other or breakout names. `group { ... }` with no breakouts is a
    single-row summary. Output shape = breakouts then aliases.
  - `sort key [, key ...]` — `-key` descending; after a `group`, keys refer
    to the grouped output including aliases. A later sort replaces an
    earlier one.
  - `limit N` / `offset N` — non-negative integer literals only, at most one
    of each; row capping stays the caller's job.
- **Staged compilation.** Stages fold onto one Ecto query; the first
  column-referencing stage after a projection (or after `limit`/`offset` on
  a projected level) wraps the accumulated query in a subquery, so `filter`
  after `group` is HAVING semantics with no special case. Consecutive
  same-shape stages share a query level. Output field specs flow stage to
  stage (breakouts keep the underlying field type, `sum`/`min`/`max` keep
  their argument's, `count*` are `:integer`), so coercion and
  `literal_transform:` keep working over grouped output.
- **Positional output columns (atom safety).** Aliases never become atoms:
  projections select into the fixed key set `:c0..:c63` (max 64 columns per
  stage) and `build_pipe/2` returns `{:ok, query, columns}` where `columns`
  is the ordered `%{name: "total", key: :c1}` rename mapping (`nil` when no
  projection stage ran). A hostile flood of unique alias/table/slug/column
  names cannot grow the atom table — covered by regression tests.
- **`@slug` external references** (`@monthly-revenue`; slugs
  `[a-z0-9][a-z0-9-_]*`) resolve through the new `resolve_source:` option:
  `fn slug -> {:ok, queryable, fields} | {:error, message} end`. The
  queryable is inlined as a subquery source and `fields` (an
  `allowed_fields`-format spec of its output) validates and types the
  stages that follow. Missing resolver, resolver errors, and off-contract
  returns are clear build errors carrying the source's position.
- **Positioned validation errors** — new `EctoQueryParser.ValidationError`
  exception struct with `message`, `line`/`column`/`byte_offset`, `stage`,
  and `stage_index`. Identifiers, aliases, and stage keywords carry source
  positions through the pipe AST, so unknown columns in
  `select`/`group`/`sort`, alias collisions, plural associations outside
  filters, unresolvable `@refs`, and duplicate `limit`/`offset` stages point
  at the offending token. Boundary: errors arising *inside* a `filter`
  stage's boolean expression keep the plain `{:error, binary}` shape
  (prefixed with `"in filter stage N: "`) — the filter grammar's AST carries
  no per-token positions.
- **`EctoQueryParser.parameters/1` accepts pipe queries** (text or parsed
  struct), collecting `{{name}}` parameters across all filter stages with
  the same `required` semantics.

### Added — parameters and literals

- **`{{name}}` parameters.** Placeholders are valid anywhere a literal may
  appear (right side of comparisons, list elements, function arguments,
  BETWEEN bounds); names match `[A-Za-z_][A-Za-z0-9_]*` and whitespace
  inside the braces is tolerated. Values bind at build time via the new
  `params: %{"name" => value}` option on `EctoQueryParser.apply/3` and
  `Builder.build/2`, and behave exactly like inline literals: same type
  coercion against the field's type, always bound as prepared-statement
  parameters. Values without a literal syntax (`Date`, `Decimal`, ...) can
  be passed directly. An unbound parameter (missing key or `nil`) is a
  build error: `{:error, "missing required parameter: name"}`. Parameter
  names stay strings end to end — no atoms.
- **`[[ ... ]]` optional groups.** A bracketed group carries its `AND`/`OR`
  connector *inside* the brackets and attaches to the surrounding boolean
  chain at that connector's precedence level
  (`status == "x" [[AND created_at >= {{start}}]]`); a connector-less
  `[[expr]]` may stand as the whole filter (degenerating to `WHERE TRUE`
  when pruned). If every `{{param}}` in a group is bound, the group
  participates as if the brackets were absent; if any is unbound, the whole
  group is pruned before building. Groups with no parameters are always
  included. Groups do not nest; unmatched or nested brackets are
  `ParseError`s with positions. Pruning runs after parse and before the
  EXISTS rewriter, so groups compose with plural-association predicates
  (merging into the same `EXISTS`) and `NOT`.
- **`EctoQueryParser.parameters/1`** — parameter discovery. Returns
  `{:ok, [%{name: "status", required: true}, ...]}` in order of first
  appearance; `required` is `false` iff every occurrence of the name sits
  inside optional groups. Parse failures return the usual
  `{:error, %ParseError{}}`.
- **`literal_transform:` build option** — a `fun(ecto_type, raw_string)`
  hook called for string literals (and bound string parameter values)
  resolved against a typed field, before the built-in coercion — on plain
  fields, association-path leaves (including inside `EXISTS`), BETWEEN
  bounds, IN elements, `includes`, and LIKE/ILIKE patterns. Returns:
  - `:default` — today's behavior (coercion + `type/2` wrap);
  - `{:ok, term}` — replace the value, bound as a plain pin with no
    `type/2` wrap (the transform owns the type);
  - `{:range, {lo, hi}}` — the literal denotes an inclusive range,
    compiled per operator: `==` → `>= lo AND <= hi`, `!=` → its negation,
    `>=` → `>= lo`, `>` → `> hi`, `<=` → `<= hi`, `<` → `< lo`; BETWEEN
    bounds resolve independently (low takes `lo`, high takes `hi`); a
    literal on the left flips the operator first. `{:range, _}` for any
    other operator (IN elements, LIKE, `includes`) is a build error with a
    clear message.

### Changed

- `ROUND_*` functions now inline their `DATE_TRUNC` unit as a SQL literal
  (`DATE_TRUNC('month', ...)`) instead of binding it as a parameter. The
  unit comes from a fixed internal map (never from input), and inlining
  keeps the expression textually identical wherever it repeats — required
  for grouped SELECT/GROUP BY expressions to match under Postgres.

### Fixed

- Building a list containing a non-literal (e.g. an identifier) now returns
  `{:error, "lists may only contain literal values, ..."}` instead of
  raising a `FunctionClauseError`.

## v0.4.0

### Security

- **Fixed an atom-exhaustion vulnerability in dotted-identifier resolution.**
  `resolve_dotted_identifier/2` and the JSON-path resolver called
  `String.to_atom/1` on raw input *before* any allowlist check, so a hostile
  stream of unique dotted identifiers (`a.b1 == 1`, `a.b2 == 1`, …) could
  grow the BEAM atom table without bound and crash the node. Since this
  library's entire purpose is filtering by untrusted input, treat this as a
  mandatory upgrade. No code path converts input to atoms anymore:
  - Allowlist (`:allowed_fields`) checks now compare strings.
  - Association segments and leaf fields resolve via
    `String.to_existing_atom/1`; unknown names return the usual
    `"unknown field: ..."` / `"unknown association: ..."` errors.
  - JSON path segments stay plain strings all the way into
    `json_extract_path/2` — they never touch the atom table.
  - Regression tests assert the atom count stays flat under hostile input.

### Changed (BREAKING)

- **Parse failures now return `{:error, %EctoQueryParser.ParseError{}}`
  instead of `{:error, binary}`.** The struct is an `Exception` carrying
  `message`, `line` (1-based), `column` (1-based), `byte_offset`, and `rest`
  (the unconsumed input, truncated) — enough to power editor diagnostics.
  `Exception.message/1` renders a one-liner including the position. This
  applies to `EctoQueryParser.parse/1` and propagates through
  `EctoQueryParser.apply/3`. Code matching `{:error, reason} when
  is_binary(reason)` on *parse* failures must be updated; builder/validation
  errors (unknown field, field not allowed, unknown function, …) keep their
  `{:error, binary}` shape, since no source position is known at that stage.

### Added

- Strict comparison operators `>` and `<` (with the same literal type
  coercion as `>=` / `<=`).
- `NOT` — unary logical negation: `NOT expr`, `NOT (a OR b)`. Precedence is
  `NOT` > `AND` > `OR`. Accepts `NOT` / `not`, like the other keywords.
  Negating a plural-association predicate now produces `NOT EXISTS`,
  lifting the v0.3.0 limitation ("posts with no matching comments" works).
- `IS NULL` / `IS NOT NULL` — postfix on identifiers, association paths,
  JSON paths, and function expressions; compiles to `is_nil/1` /
  `not is_nil/1`.
- `IN` — list membership: `age IN [18, 21]`, `status in ["a", "b"]`. List
  elements are type-coerced against the field's type the same way `==`
  coerces its literal.
- `BETWEEN` — `field BETWEEN low AND high` compiles to
  `field >= low and field <= high`, with both bounds coerced to the field's
  type. The inner `AND` binds to `BETWEEN`, not the logical connector.
- All new operators work on plain fields, association paths (respecting the
  JOIN vs EXISTS split for plural associations), and inside parentheses.
- Parse-failure messages are now labeled and concise instead of
  NimbleParsec's exhaustive expected-token dump.

## v0.3.1

### Fixed

- `many_to_many` filters with `:join_prefix` crashed with
  `FunctionClauseError` in `Ecto.Queryable.Tuple.to_query/1`. The EXISTS
  subquery built the inner-join source as a `{prefix, table}` string tuple
  and pinned it into the join macro; at runtime that falls through
  `Ecto.Queryable.to_query/1` which only accepts `{string, atom}` tuples.
  The prefix is now passed via `join/5`'s `:prefix` keyword option, the
  same pattern used for prefixed belongs-to joins.

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
