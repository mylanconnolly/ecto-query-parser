# EctoQueryParser

A query language parser for Ecto that converts human-readable filter strings into
Ecto `WHERE` clauses. Useful for building user-facing search and filtering
interfaces where the filter expression comes from a URL parameter, API request
body, or other untrusted text input. It also ships a staged
[pipe language](#pipe-language) (`source | filter … | group … | sort … | limit N`)
for building whole BI-style queries from untrusted text.

```elixir
iex> EctoQueryParser.apply(Post, ~s{status == "published" AND author.name contains "alice"})
{:ok, #Ecto.Query<...>}
```

## Installation

Add `ecto_query_parser` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:ecto_query_parser, "~> 0.1.0"}
  ]
end
```

## Query Language

### Data Types

| Type | Examples |
|------|---------|
| String | `"hello"`, `"with \"escapes\""` |
| Integer | `42`, `-7` |
| Float | `3.14`, `-0.5` |
| Boolean | `true`, `false` (case-insensitive) |
| List | `[1, 2, 3]`, `["a", "b"]` |

### Operators

| Operator | Example | Description |
|----------|---------|-------------|
| `==` | `age == 42` | Equality |
| `!=` | `status != "banned"` | Inequality |
| `>=` | `age >= 18` | Greater than or equal |
| `<=` | `score <= 9.99` | Less than or equal |
| `>` | `age > 18` | Strictly greater than |
| `<` | `score < 9.99` | Strictly less than |
| `IN` | `age IN [18, 21, 65]` | List membership; elements are coerced to the field's type |
| `BETWEEN` | `age BETWEEN 18 AND 65` | Inclusive range (`>= low AND <= high`); the inner `AND` binds to `BETWEEN` |
| `IS NULL` | `name IS NULL` | Null check (`is_nil`) |
| `IS NOT NULL` | `name IS NOT NULL` | Non-null check |
| `contains` | `name contains "ali"` | Case-insensitive substring match (ILIKE) |
| `like` | `name like "%ali%"` | SQL LIKE pattern |
| `ilike` | `name ilike "%ALI%"` | SQL ILIKE pattern |
| `search` | `body search "elixir programming"` | Splits into words and ANDs ILIKE matches |
| `includes` | `tags includes "elixir"` | Array containment (`= ANY(...)`) |

All operators work on plain fields, association paths (`author.hired_on
BETWEEN "2026-01-01" AND "2026-12-31"`), and JSON paths.

### Logical Operators

Combine conditions with `AND` and `OR`, negate with `NOT`, and use
parentheses for grouping. Keywords accept all-uppercase or all-lowercase.
Precedence: `NOT` binds tighter than `AND`, which binds tighter than `OR`.

```
name == "alice" AND age >= 18
role == "admin" OR role == "moderator"
(role == "admin" OR role == "moderator") AND active == true
NOT (role == "admin" OR role == "moderator")
NOT comments.body contains "spam"
```

`NOT` on a plural-association predicate produces a `NOT EXISTS` subquery
("posts with no matching comments").

### Parameters

`{{name}}` placeholders may appear anywhere a literal may appear — the right
side of comparisons, list elements, function arguments, `BETWEEN` bounds.
Names match `[A-Za-z_][A-Za-z0-9_]*` and whitespace inside the braces is
tolerated (`{{ status }}`).

Values are bound at build time via the `:params` option:

```elixir
{:ok, query} =
  EctoQueryParser.apply(Post, "status == {{status}} AND published_on >= {{start}}",
    params: %{"status" => "published", "start" => "2026-01-01"}
  )
```

Bound values behave exactly like inline literals of that value: they receive
the same type coercion against the field's type (the `"2026-01-01"` above is
cast to the `:date` column) and are always bound as prepared-statement
parameters. Values without a literal syntax (`Date`, `DateTime`, `Decimal`,
...) can be passed directly. Atom keys are accepted as a convenience
(`params: %{status: "published"}`).

An unbound parameter — key missing or value `nil` — is a build error:

```elixir
{:error, "missing required parameter: status"}
```

...unless every occurrence of it sits inside an optional group (below).

Use `EctoQueryParser.parameters/1` to discover the parameters a filter
references, in order of first appearance:

```elixir
EctoQueryParser.parameters("status == {{status}} [[AND created_at >= {{start}}]]")
#=> {:ok, [%{name: "status", required: true}, %{name: "start", required: false}]}
```

`required` is `false` iff every occurrence of the name is inside optional
groups. Parse failures return `{:error, %EctoQueryParser.ParseError{}}`.

### Optional groups

`[[ ... ]]` wraps a boolean fragment that should only apply when its
parameters are bound — the same convention used by raw-SQL templating
libraries. The `AND`/`OR` connector lives *inside* the brackets:

```
status == "live" [[AND created_at >= {{start}}]] [[AND region == {{region}}]]
```

- If **every** `{{param}}` inside a group is bound (non-`nil`), the group
  participates exactly as if the brackets weren't there.
- If **any** is unbound, the entire group is pruned from the query before
  building — neutral, as if the text were absent.
- A group containing no parameters is always included.

With `params: %{"start" => "2026-01-01"}` the filter above becomes
`status == "live" AND created_at >= {{start}}`; with `params: %{}` it becomes
just `status == "live"`.

Grammar rules:

- A group attaches to the chain at its connector's precedence level, so it
  must contain a fragment that composes there: `a [[OR b AND c]]` works
  (`OR` element), while `a [[AND b OR c]]` is a parse error — write
  `a [[AND (b OR c)]]`.
- A connector-less group may appear where an expression begins, most
  usefully as the entire filter: `[[status == {{s}}]]` (optionally followed
  by further groups: `[[status == {{s}}]] [[AND region == {{r}}]]`). If
  everything prunes away, the filter degenerates to `WHERE TRUE`.
- Optional groups do not nest; unmatched or nested brackets are
  `ParseError`s with position information.
- Groups compose with the full operator set, including plural-association
  predicates (a pruned or included group merges into the surrounding
  `EXISTS` normally) and `NOT` (inside the group; `NOT [[...]]` is a parse
  error).

### Functions

Functions are case-insensitive and can be nested.

**String functions:**

| Function | Example |
|----------|---------|
| `UPPER(field)` / `TO_UPPER(field)` | `UPPER(name) == "ALICE"` |
| `LOWER(field)` / `TO_LOWER(field)` | `LOWER(name) == "alice"` |
| `TRIM(field)` | `TRIM(name) == "alice"` |
| `LENGTH(field)` | `LENGTH(name) >= 3` |
| `LEFT(field, n)` | `LEFT(name, 3) == "ali"` |
| `RIGHT(field, n)` | `RIGHT(name, 3) == "ice"` |
| `SUBSTRING(field, start, len)` | `SUBSTRING(name, 1, 3) == "ali"` |
| `CONCAT(a, b, ...)` | `CONCAT(first, last) == "alicebob"` |
| `REPLACE(field, from, to)` | `REPLACE(name, "alice", "bob") == "bob"` |
| `COALESCE(field, default)` | `COALESCE(name, "unknown") == "unknown"` |

**Math functions:**

| Function | Example |
|----------|---------|
| `ABS(field)` | `ABS(balance) >= 100` |
| `FLOOR(field)` | `FLOOR(score) == 3` |
| `CEIL(field)` | `CEIL(score) == 4` |

**Date/time functions:**

| Function | Description |
|----------|-------------|
| `NOW()` | Current timestamp |
| `ROUND_SECOND(field)` through `ROUND_YEAR(field)` | Truncates to the given precision via `DATE_TRUNC` |
| `ADD_INTERVAL(field, interval)` | `ADD_INTERVAL(created_at, "1 day") >= NOW()` |
| `SUB_INTERVAL(field, interval)` | `SUB_INTERVAL(created_at, "2 hours") <= NOW()` |

The `ROUND_*` family includes: `ROUND_SECOND`, `ROUND_MINUTE`, `ROUND_HOUR`,
`ROUND_DAY`, `ROUND_WEEK`, `ROUND_MONTH`, `ROUND_QUARTER`, `ROUND_YEAR`.

## Pipe language

Beyond single filter strings, the package parses a staged **pipe language** —
a text query language for BI-style tools where end users type whole queries
(projection, aggregation, ordering) against allowlist-bounded schemas. A pipe
query is a source plus a flat list of `|`-separated stages; whitespace and
newlines around `|` are insignificant:

```
orders
| filter status == "paid" AND created_at >= "last month"
| group customer.region {
    total = sum(amount),
    n = count()
  }
| sort -total
| limit 10
```

```elixir
{:ok, query, columns} =
  EctoQueryParser.build_pipe(text,
    allowed_fields: [status: :string, amount: :integer, created_at: :utc_datetime,
                     customer: {:belongs_to, table: "customers", owner_key: :customer_id,
                                related_key: :id, fields: [region: :string]}],
    literal_transform: my_date_transform
  )

columns
#=> [%{name: "customer.region", key: :c0}, %{name: "total", key: :c1}, %{name: "n", key: :c2}]

Repo.all(query)
#=> [%{c0: "north", c1: 1200, c2: 8}, ...]
```

Use `EctoQueryParser.parse_pipe/1` to parse without building (e.g. to inspect
the query's source), and `EctoQueryParser.parameters/1` works on pipe texts
too (parameters may appear in any `filter` stage).

### Stages

| Stage | Example | Description |
|-------|---------|-------------|
| `filter <expr>` | `filter status == "paid" AND age >= {{min}}` | The full filter grammar, verbatim — operators, functions, association paths (JOIN/EXISTS), JSONB paths, `{{params}}`, `[[optional]]` groups. Multiple `filter` stages allowed. After a `group`/`select`, filters address the previous stage's *output* (HAVING semantics for free). |
| `select col, ...` | `select name, customer.region, upper_name = UPPER(name)` | Projection. Columns are identifiers (association paths, singular-only) or `alias = FUNC(...)` using the existing function set. Later stages see only the selected columns. |
| `group breakouts { aggs }` | `group region { total = sum(amount), n = count() }` | Aggregation. Breakouts are identifiers, function applications (`ROUND_*` temporal bucketing), or `alias = FUNC(...)`; aggregations are `count()`, `count(col)`, `count_distinct(col)`, `sum(col)`, `avg(col)`, `min(col)`, `max(col)`, each aliased. `group { ... }` with no breakouts is a single-row summary. Output shape = breakouts then aliases. |
| `sort key, ...` | `sort -total, region` | `-key` sorts descending. After a `group`, keys refer to the grouped output, aliases included. A later `sort` replaces an earlier one. |
| `limit N` / `offset N` | `limit 10` | Non-negative integer literals only (never parameters); at most one of each per query. Row capping stays the caller's job — apply your hard cap to the returned query. |

Stage keywords are lowercase. An un-aliased function breakout gets a derived,
referenceable name (`ROUND_MONTH(created_at)` → `round_month_created_at`);
alias it (`month = ROUND_MONTH(created_at)`) for a nicer one. Aliases must
not collide with each other or with breakout/column names.

### Output columns

Aliases come from untrusted input and are **never converted to atoms**
(Ecto's map selects and subqueries need atom keys, and hostile unique aliases
would otherwise exhaust the atom table). Instead, every projection stage
selects into positional keys `:c0`, `:c1`, … (at most 64 columns per stage),
and `build_pipe/2` returns the ordered name→key mapping so you can rename
result rows. Queries with no projection stage return `nil` columns and keep
the source's row shape — note a schemaless table source then has no select
clause, so attach one before executing.

### Staged compilation

Stages fold left-to-right onto one Ecto query. A stage that must address the
previous stage's *output* (the first filter/select/group/sort after a
projection, or any of those after `limit`/`offset`) wraps the accumulated
query in a subquery; consecutive same-shape stages share a level (two
adjacent filters are two WHERE clauses, no nesting). This is how `filter`
after `group` becomes HAVING semantics without a special case:

```
orders | group region { total = sum(amount) } | filter total > 100
```

```sql
SELECT s0."c0", s0."c1" FROM (
  SELECT o0."region" AS "c0", sum(o0."amount") AS "c1"
  FROM "orders" AS o0 GROUP BY o0."region"
) AS s0 WHERE s0."c1" > $1
```

Grouped output columns keep type information (breakouts keep the underlying
field's type; `sum`/`min`/`max` keep their argument's), so literal coercion
and `literal_transform` keep working in post-group filters.

### Sources and `@references`

A **table source** (`orders`, or schema-qualified `sales.orders`, which sets
the query prefix) compiles to a schemaless `from`. The table name itself is
not validated — parse first, check `source` against your catalog, then build
with that table's field spec:

```elixir
{:ok, %EctoQueryParser.Pipe.Query{source: {:table, "orders", _pos}}} =
  EctoQueryParser.parse_pipe(text)
```

An **external reference** (`@monthly-revenue`; slugs are
`[a-z0-9][a-z0-9-_]*`) is resolved through the `:resolve_source` option —
this is how a BI app implements "query another saved question". The resolver
receives the slug and returns the queryable *and* its output field spec (in
`:allowed_fields` format), so stages can be validated and typed against it:

```elixir
resolve_source: fn slug ->
  case MyApp.Questions.fetch(slug) do
    {:ok, question} -> {:ok, question.query, question.fields}
    :error -> {:error, "no such question"}
  end
end

EctoQueryParser.build_pipe("@monthly-revenue | filter total > 100 | sort -total",
  resolve_source: resolver)
```

The resolved queryable is inlined as a subquery source (it must carry a
select, as any schema-based or previously-built query does). The package
never interprets slugs — lookup, permissions, and cycle detection are the
caller's problem. A `@slug` without a resolver is a build error.

### Pipe errors

Parse failures return the usual positioned `%EctoQueryParser.ParseError{}`.
Stage-level validation failures (unknown column in `select`/`sort`/`group`,
alias collisions, plural association outside a filter, unresolvable
`@reference`, more than one `limit`, …) return a positioned
`%EctoQueryParser.ValidationError{}` — identifiers, aliases, and stage
keywords carry their source position through the AST, and the error names
the stage that broke:

```elixir
{:error, %EctoQueryParser.ValidationError{} = err} =
  EctoQueryParser.build_pipe("orders | group region { t = sum(amount) } | sort -bogus")

Exception.message(err)
#=> "invalid query at line 1, column 51 (in sort stage 2): unknown column: bogus (output columns: region, t)"
```

Errors arising *inside* a `filter` stage's boolean expression (unknown
field, unbound parameter, …) reuse the existing filter builder and keep
their plain `{:error, binary}` shape, prefixed with the stage — the filter
grammar's AST does not carry per-token positions:

```elixir
{:error, "in filter stage 2: unknown column: age (output columns: name)"}
```

## Usage

### Basic Usage

Pass an Ecto schema module or an existing `Ecto.Query` along with a filter string:

```elixir
# With a schema module
{:ok, query} = EctoQueryParser.apply(MyApp.Post, ~s{status == "published"})
Repo.all(query)

# Composing with an existing query
import Ecto.Query
base = from(p in MyApp.Post, select: p.title)
{:ok, query} = EctoQueryParser.apply(base, ~s{author.name == "alice"})
Repo.all(query)
```

### Association Joins

Dotted identifiers automatically resolve to SQL based on the association's
cardinality. **`belongs_to`** and **`has_one`** produce `LEFT JOIN` clauses;
**`has_many`** and **`many_to_many`** produce correlated `EXISTS` subqueries
(so plural matches don't duplicate parent rows). Multiple references to the
same singular association deduplicate into a single join.

```elixir
# belongs_to → LEFT JOIN
{:ok, query} = EctoQueryParser.apply(Post, ~s{author.name == "alice"})

# Multi-level belongs_to → multiple LEFT JOINs
{:ok, query} = EctoQueryParser.apply(Post, ~s{author.company.name == "Acme"})

# Deduplication: only one join for author
{:ok, query} = EctoQueryParser.apply(Post, ~s{author.name == "alice" AND author.email contains "example"})

# has_many → EXISTS (no row duplication)
{:ok, query} = EctoQueryParser.apply(Post, ~s{comments.body contains "ship"})

# many_to_many → EXISTS through the join table
{:ok, query} = EctoQueryParser.apply(Post, ~s{tags.name == "elixir"})
```

When multiple predicates reference the same plural alias under the same
boolean connector, they collapse into a single EXISTS:

```elixir
# One EXISTS clause, both predicates AND-ed inside:
EctoQueryParser.apply(Post, ~s{comments.spam == false AND comments.body contains "ship"})

# Different plural aliases stay separate:
EctoQueryParser.apply(Post, ~s{comments.body contains "x" AND likes.user_id == 42})
```

v1 restriction: a plural association may only appear as the first segment of
a dotted path. `comments.author.name` is allowed (plural first, then
belongs_to); `author.comments.body` is not.

#### Performance note

`EXISTS` subqueries on plural associations rely on an index covering the
child-side FK column (`comments(post_id)`, `post_tags(post_id)`, etc.). The
SQL is otherwise correct but can fall off a performance cliff against a
large table without that index. Add one if you're filtering through a
plural association on a non-trivial dataset.

### JSONB Column Access

When a dotted identifier refers to a `:map` field on the schema, it extracts the
value via `json_extract_path` instead of creating a join. Nested paths work too.

```elixir
# Schema: field :metadata, :map
{:ok, query} = EctoQueryParser.apply(Post, ~s{metadata.category == "tech"})
# Generates: WHERE metadata#>'{category}' = 'tech'

# Nested path
{:ok, query} = EctoQueryParser.apply(Post, ~s{metadata.author.name == "alice"})
```

For correct type casting on JSON values (required for numeric and boolean
comparisons), provide types via the keyword list format of `:allowed_fields`:

```elixir
{:ok, query} = EctoQueryParser.apply(Post, ~s{metadata.view_count >= 100},
  allowed_fields: [metadata: :map, "metadata.view_count": :integer]
)
```

### Restricting Fields

Use `:allowed_fields` to control which fields users can filter on. Two formats
are supported:

```elixir
# Plain list: access control only
EctoQueryParser.apply(Post, query_string,
  allowed_fields: [:name, :age, :"author.name"]
)

# Keyword list: access control + type casting for JSON paths
EctoQueryParser.apply(Post, query_string,
  allowed_fields: [
    name: :string,
    age: :integer,
    metadata: :map,
    "metadata.key": :string,
    "metadata.count": :integer
  ]
)
```

Fields not in the list return `{:error, "field not allowed: ..."}`.

### Schemaless Queries

When working with a string table name instead of a schema module, define
associations directly in `:allowed_fields`. Three relationship tuples are
supported; `{:assoc, ...}` is a backward-compatible alias for `{:belongs_to, ...}`.

```elixir
import Ecto.Query

allowed = [
  name: :string,

  # belongs_to → LEFT JOIN
  author: {:belongs_to,
    table: "users",
    owner_key: :author_id,
    related_key: :id,
    fields: [name: :string, email: :string]},

  # has_many → EXISTS subquery
  comments: {:has_many,
    table: "comments",
    owner_key: :id,
    related_key: :post_id,
    fields: [body: :string, spam: :boolean]},

  # many_to_many → EXISTS through join table
  tags: {:many_to_many,
    table: "tags",
    join_through: "post_tags",
    join_owner_key: :post_id,
    join_related_key: :tag_id,
    owner_key: :id,
    related_key: :id,
    fields: [name: :string]}
]

{:ok, query} = EctoQueryParser.apply(
  from("posts"),
  ~s{author.name == "alice" AND comments.body contains "ship"},
  allowed_fields: allowed
)
```

Common options (all three tuples accept these):

- `:table` (required) - target table name as a string
- `:fields` (optional) - keyword list of permitted fields, supports nesting
- `:prefix` (optional) - schema prefix for the target table (multi-tenant)

`belongs_to` / `has_many` additionally require `:owner_key` and `:related_key`.
For `belongs_to`, `:owner_key` is the FK on the source and `:related_key` is
the PK on the target; for `has_many` they are swapped (PK on source, FK on
target).

`many_to_many` additionally requires `:join_through` (the join table name),
`:join_owner_key` and `:join_related_key` (the join table's FK columns), and
optionally `:join_prefix` (a schema prefix for the join table).

### Natural-language literals

The `:literal_transform` build option lets you intercept string literals
(and bound string parameter values) before the built-in type coercion — for
example to accept human date phrases:

```elixir
transform = fn
  :date, "last year" -> {:range, {~D[2025-01-01], ~D[2025-12-31]}}
  :date, "today"     -> {:ok, Date.utc_today()}
  _type, _raw        -> :default
end

{:ok, query} =
  EctoQueryParser.apply(Post, ~s{published_on == "last year"},
    literal_transform: transform
  )
```

The function is called as `fun.(ecto_type, raw_string)` whenever a string
literal is resolved against a field with a known Ecto type — on plain
fields, association-path leaves (the coercion walk already knows the leaf
type, including inside `EXISTS` subqueries), `BETWEEN` bounds, `IN` list
elements, `includes`, and `LIKE`/`ILIKE` patterns. It may return:

- `:default` — fall through to the existing behavior (coercion + `type/2`
  wrapping).
- `{:ok, term}` — replace the value. The term is bound as a plain
  prepared-statement parameter with **no** `type/2` wrap; the transform owns
  the type.
- `{:range, {lo, hi}}` — the literal denotes an **inclusive** range, which
  compiles per operator:

  | Operator | Compiles to |
  |----------|-------------|
  | `== `    | `field >= lo AND field <= hi` |
  | `!=`     | `NOT (field >= lo AND field <= hi)` |
  | `>=`     | `field >= lo` |
  | `>`      | `field > hi` |
  | `<=`     | `field <= hi` |
  | `<`      | `field < lo` |
  | `BETWEEN a AND b` | each bound resolves independently — `a` uses its `lo`, `b` uses its `hi` |

  A literal on the left side flips the operator first
  (`"last year" <= field` ≡ `field >= ...`). Range results are only
  meaningful for comparisons and `BETWEEN`; returning `{:range, _}` for
  anything else (`IN` elements, `LIKE` patterns, `includes`) is a build
  error.

The transform is not called when no field type is known (e.g. schemaless
queries without types in `:allowed_fields`, or function arguments), and it
is not called for `contains`/`search`, whose strings are treated as match
words rather than compared values.

### Error Handling

All errors are returned as `{:error, reason}` tuples.

**Parse failures** (since v0.4.0) return an `EctoQueryParser.ParseError`
struct carrying position information for editor diagnostics:

```elixir
{:error, %EctoQueryParser.ParseError{} = err} = EctoQueryParser.parse("a == 1 AND")
err.line        # 1 (1-based)
err.column      # 8 (1-based)
err.byte_offset # 7
err.rest        # "AND" (unconsumed input, truncated)
Exception.message(err)
# => "parse error at line 1, column 8: expected end of string"
```

**Builder/validation errors** keep their string shape (no source position is
known at that stage):

```elixir
{:error, "field not allowed: secret"}
{:error, "unknown field: nonexistent"}
{:error, "unknown association: nonexistent"}
{:error, "unknown function: bogus"}
{:error, "missing required parameter: start"}
{:error, "contains operator requires a string or identifier value, got: ..."}
```

### Safety

The library is designed for untrusted input: identifiers are never converted
to atoms unless they already exist (so hostile input cannot exhaust the BEAM
atom table), parameter names stay plain strings, JSON path segments stay
plain strings, and `contains` / `search` escape LIKE metacharacters. Combine
with `:allowed_fields` to control exactly what users can filter on.

## Development

### Running Tests

```bash
# Unit tests only (no database required)
mix test

# Start PostgreSQL for integration tests
docker compose up -d

# Run all tests including integration
mix test --include integration
# or
mix test.integration
```

Integration tests execute every generated SQL query against a real PostgreSQL
database to verify correctness beyond what `inspect(query)` assertions can catch.

## License

See [LICENSE](LICENSE) for details.
