# EctoQueryParser

A query language parser for Ecto that converts human-readable filter strings into
Ecto `WHERE` clauses. Useful for building user-facing search and filtering
interfaces where the filter expression comes from a URL parameter, API request
body, or other untrusted text input.

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
| `contains` | `name contains "ali"` | Case-insensitive substring match (ILIKE) |
| `like` | `name like "%ali%"` | SQL LIKE pattern |
| `ilike` | `name ilike "%ALI%"` | SQL ILIKE pattern |
| `search` | `body search "elixir programming"` | Splits into words and ANDs ILIKE matches |
| `includes` | `tags includes "elixir"` | Array containment (`= ANY(...)`) |

### Logical Operators

Combine conditions with `AND` and `OR` (case-insensitive). Use parentheses for
grouping. `AND` binds tighter than `OR`.

```
name == "alice" AND age >= 18
role == "admin" OR role == "moderator"
(role == "admin" OR role == "moderator") AND active == true
```

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

### Error Handling

All errors are returned as `{:error, reason}` tuples:

```elixir
{:error, "field not allowed: secret"}
{:error, "unknown field: nonexistent"}
{:error, "unknown association: nonexistent"}
{:error, "unknown function: bogus"}
{:error, "contains operator requires a string or identifier value, got: ..."}
```

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
