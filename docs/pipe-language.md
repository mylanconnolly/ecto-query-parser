# The pipe language

*Design document, 2026-07-28. Grammar decisions here are settled unless revisited
explicitly; the roadmap section maps them to releases.*

Today ecto_query_parser parses a filter expression into an Ecto WHERE clause.
This document specifies its growth into a full staged query language — a text
query language for BI-style tools where end users type queries against
untrusted-input-safe, allowlist-bounded schemas.

The target shape:

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

## Design principles

1. **Staged, MBQL-5-flavored.** A query is a source plus a flat list of stages.
   Each stage consumes the previous stage's output; compilation folds stages
   onto an Ecto query, wrapping in a subquery whenever a stage references the
   previous stage's *output* shape (e.g. `filter` after `group` is HAVING
   semantics for free). No nested-source special cases.
2. **Untrusted input end to end.** Everything holds to the v0.4.0 posture: no
   atom creation from input, allowlist-bounded field resolution, values bind as
   Ecto parameters — never string splices.
3. **App-agnostic.** The package knows nothing about "questions" or catalogs.
   External references and natural-language literals enter through caller
   callbacks (`:resolve_source`, `:literal_transform`).
4. **The filter grammar is unchanged.** Everything valid in a v0.4 filter
   string is valid, verbatim, in a `| filter` stage.

## Query shape

```
query      = source , { "|" stage } ;
source     = table_ref | external_ref ;
table_ref  = identifier , [ "." , identifier ] ;      (* orders, sales.orders *)
external_ref = "@" , slug ;                            (* @monthly-revenue *)
stage      = filter | select | group | sort | limit | offset ;
```

Whitespace (including newlines) is insignificant around `|`. A bare source with
no stages is a valid query (`SELECT *` with the caller's row cap).

### Sources

- **Table**: an identifier, optionally schema-qualified. Validated against the
  caller's schema/`:allowed_fields` spec exactly as today.
- **External reference** (`@monthly-revenue`): resolved by a caller-supplied
  callback:

  ```elixir
  resolve_source: fn slug ->
    {:ok, %Ecto.Query{} = q}     # inlined as a subquery source
    | {:ok, {:fields, fields}}   # plus the field spec of its output
    | {:error, message}
  end
  ```

  Slugs are `[a-z0-9][a-z0-9-_]*`. The package never interprets slugs; cycle
  detection, permissions, and lookup are the caller's problem. (This is how a
  BI app implements "query another saved question".)

## Stages

### `filter <boolean-expr>`

The existing v0.4 grammar, unchanged: comparison and keyword operators, `NOT`,
`IS [NOT] NULL`, `IN`, `BETWEEN`, functions, association paths with JOIN/EXISTS
semantics, JSONB paths, parentheses, `AND`/`OR`.

Multiple `filter` stages are allowed. A `filter` after a `group` addresses the
grouped output's columns (aggregation aliases included) — HAVING semantics via
the staged-compilation rule, not a special case.

### `select col [, col ...]`

Projection. Columns are identifiers (association paths allowed, singular-only
per the existing join rules) or aliased expressions:

```
| select name, customer.region, upper_name = UPPER(name)
```

Selecting restricts the output shape; later stages see only selected columns.
Computed columns beyond function application (`derive`) are a later release.

### `group [breakout [, breakout ...]] { alias = agg(...) [, alias = agg(...)] }`

Aggregation with optional breakouts:

```
| group customer.region, ROUND_MONTH(inserted_at) {
    total = sum(amount),
    n = count()
  }
| group { total = sum(amount) }        (* no breakout: single-row summary *)
```

- Breakouts: identifiers or function applications (temporal bucketing via the
  existing `ROUND_*` functions).
- Aggregations: `count()`, `count(col)`, `count_distinct(col)`, `sum(col)`,
  `avg(col)`, `min(col)`, `max(col)`. Every aggregation must be aliased —
  aliases become the output column names.
- Output shape after `group` = breakouts + aggregation aliases, in that order.
- Aliases share the identifier syntax and must not collide with each other or
  the breakout names.

### `sort key [, key ...]`

`key` is a column reference, prefixed with `-` for descending:

```
| sort -total, customer.region
```

After a `group`, keys refer to the grouped output (aliases included).

### `limit N` / `offset N`

Non-negative integer literals only (no parameters — the caller owns row caps).
At most one of each per stage list; the caller's hard cap always wins.

## Parameters

`{{name}}` is valid anywhere a literal may appear, in any stage:

```
| filter status == {{status}} AND amount >= {{min_amount}}
```

- Names: `[A-Za-z_][A-Za-z0-9_]*`. AST node: `{:param, name}`.
- Values are supplied at build time (`params: %{"status" => "paid"}`) and bind
  as Ecto parameters with the same type coercion literals get.
- An unbound parameter is an error at build time…

…unless it sits inside an **optional group**:

```
| filter 1 == 1 [[AND status == {{status}}]] [[AND created_at >= {{start}}]]
```

`[[ ... ]]` wraps any boolean sub-expression inside a `filter` stage. If every
parameter inside the group is bound, the group participates normally; if any is
unbound, the whole group is pruned from the AST before building. Optional
groups don't nest and are only valid in `filter` stages. (Syntax is
deliberately identical to the `{{tag}}`/`[[...]]` dialect used in raw-SQL
questions, so users learn one convention.)

Discovery API for building parameter UIs:

```elixir
EctoQueryParser.parameters(text)
#=> {:ok, [%{name: "status", required: false}, %{name: "min_amount", required: true}]}
```

`required` is false iff every occurrence is inside optional groups.

## Typed-literal transform (natural-language dates)

Build option:

```elixir
literal_transform: fn ecto_type, raw_string ->
  {:ok, term}            # replace the literal's value
  | {:range, {lo, hi}}   # the literal denotes an inclusive range
  | :default             # fall through to normal coercion
end
```

Called for string literals (and bound string parameter values) compared against
typed fields, before the existing `type/2` coercion. This is the integration
point for natural-language dates (e.g. chronix): with a transform installed,
`created_at >= "last month"` works.

Range semantics per comparison operator, given `{:range, {lo, hi}}`:

| operator | compiles to |
|---|---|
| `==` | `field >= lo AND field <= hi` |
| `!=` | `NOT (field >= lo AND field <= hi)` |
| `>=` | `field >= lo` |
| `>`  | `field > hi` |
| `<=` | `field <= hi` |
| `<`  | `field < lo` |
| `BETWEEN a AND b` | boundaries resolve independently: lo of `a`, hi of `b` |

## Errors

- Parse failures: `%EctoQueryParser.ParseError{message, line, column,
  byte_offset, rest}` (since v0.4.0).
- From the stage release onward, AST nodes carry source positions, and
  build/validation errors (`unknown field`, `field not allowed`, bad
  aggregation alias, …) return a positioned error struct too — so editors can
  underline the offending token, not just parse failures.

## Compilation model

`parse/1` → `[source | stages]` AST → validate against schema/field spec →
fold stages onto an Ecto query. A stage wraps the accumulated query in a
subquery iff it must address the previous stage's *output* (the first stage
after a `group` or `select` that references produced columns); consecutive
same-shape stages merge into one query level. Output field-spec tracking flows
stage to stage, so validation errors name the stage that broke.

Postgres remains the only target (fragments: `ILIKE`, `DATE_TRUNC`,
`json_extract_path`).

## Release roadmap

- **v0.5.0 — parameters.** `{{name}}` nodes, `[[optional]]` groups,
  `parameters/1` discovery, `params:` build option, `literal_transform:` hook.
  Filter-only surface (the pipe grammar is not yet exposed).
- **v0.6.0 — the pipe language.** Source + stage grammar (`filter`, `select`,
  `group`, `sort`, `limit`/`offset`), staged compilation, `@slug` +
  `resolve_source:`, positioned validation errors.
- **v0.7+ — candidates.** `derive` (computed columns), explicit `join`,
  `distinct`, window functions, percentile aggregations, non-Postgres dialects.

## Decisions log

| Date | Decision |
|---|---|
| 2026-07-28 | Pipe/stage shape with `group breakouts { alias = agg() }` blocks and `-col` descending sort (approved via reporting-plan preview) |
| 2026-07-28 | External refs are `@slug` (over `question:slug` / `#slug`) |
| 2026-07-28 | Parameters are `{{name}}` + `[[optional]]`, identical to the raw-SQL template dialect |
| 2026-07-28 | `limit`/`offset` take integer literals only, never parameters |
| 2026-07-28 | Optional groups: filter stages only, no nesting |
