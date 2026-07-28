defmodule EctoQueryParser do
  @moduledoc """
  A query language parser for Ecto.

  Parses string input into AST nodes that can be used for building Ecto queries.
  """

  import Ecto.Query

  defdelegate parse(input), to: EctoQueryParser.Parser

  @doc """
  Parses a query string and applies it as a WHERE clause to the given queryable.

  Supports dotted identifiers (e.g., `author.name`) that automatically resolve
  to left joins on schema associations, or to JSONB path extraction when the
  first segment refers to a `:map` field on the schema.

  ## JSONB column support

  When a dotted identifier like `metadata.key` is used and the schema defines
  `metadata` as a `:map` field, the builder uses `json_extract_path/2` instead
  of creating a join. Nested paths like `metadata.nested.key` are supported.

  To enable type casting on JSON values (essential for numeric/boolean comparisons),
  use the keyword list format for `:allowed_fields`.

  ## Parameters and optional groups

  `{{name}}` placeholders may appear anywhere a literal may appear and are
  bound at build time via the `:params` option (`params: %{"name" => value}`).
  Bound values behave exactly like inline literals: they get the same type
  coercion against the field's type and are bound as prepared-statement
  parameters. An unbound (missing or `nil`) parameter is a build error —
  unless every occurrence sits inside an `[[ ... ]]` optional group, in which
  case the group is pruned from the query:

      status == {{status}} [[AND created_at >= {{start}}]]

  Use `parameters/1` to discover the parameters a filter string references.

  ## Options

    * `:params` - map binding `{{name}}` parameters to values
      (`%{"name" => value}`; atom keys are also accepted).

    * `:literal_transform` - `fun(ecto_type, raw_string)` invoked for string
      literals (and bound string parameter values) compared against a typed
      field, before the built-in coercion. Return `{:ok, term}` to replace
      the value, `{:range, {lo, hi}}` to expand the literal into an inclusive
      range (comparison and BETWEEN operators only), or `:default` to keep
      the normal behavior.

    * `:allowed_fields` - controls which fields are permitted. Supports two formats:
      - **Plain list** (access control only): `[:name, :age, :"metadata.key"]`
      - **Keyword list** (access control + type casting):
        `[name: :string, metadata: :map, "metadata.key": :string, "metadata.age": :integer]`

      When the keyword format provides a type for a JSON sub-path, the result is
      wrapped with `type/2` for proper casting. Without type info, raw
      `json_extract_path` is used.

      Dotted paths use atom notation (e.g., `:"author.name"`).

    * **Schemaless queries** — when using a string table name (e.g., `from("posts")`),
      associations can be defined directly in `allowed_fields`. Three relationship
      kinds are recognized; `{:assoc, opts}` remains a backward-compatible alias
      for `{:belongs_to, opts}`.

          allowed_fields: [
            name: :string,

            # belongs_to (LEFT JOIN)
            author: {:belongs_to,
              table: "users",
              owner_key: :author_id,
              related_key: :id,
              fields: [name: :string, email: :string]},

            # has_many (EXISTS subquery; no row duplication)
            comments: {:has_many,
              table: "comments",
              owner_key: :id,
              related_key: :post_id,
              fields: [body: :string, spam: :boolean]},

            # many_to_many (EXISTS through join table)
            tags: {:many_to_many,
              table: "tags",
              join_through: "post_tags",
              join_owner_key: :post_id,
              join_related_key: :tag_id,
              owner_key: :id,
              related_key: :id,
              fields: [name: :string]}
          ]

      Options shared by all three:
        - `:table` — target table name (string, required)
        - `:fields` — nested allowed_fields; supports further nesting (optional)
        - `:prefix` — schema prefix for the target table (optional, multi-tenant)

      `belongs_to` and `has_many` additionally require:
        - `:owner_key` — FK on the source for belongs_to; PK on the source for has_many
        - `:related_key` — PK on the target for belongs_to; FK on the target for has_many

      `many_to_many` additionally requires:
        - `:join_through` — name of the join table (string)
        - `:join_owner_key` — FK in the join table pointing at the source
        - `:join_related_key` — FK in the join table pointing at the target
        - `:owner_key` / `:related_key` — the columns those FKs point at
        - `:join_prefix` — optional schema prefix for the join table

      When an Ecto schema is available, association cardinality is auto-detected
      from `__schema__(:association, name)` — `belongs_to`/`has_one` use
      `LEFT JOIN`, `has_many`/`many_to_many` use `EXISTS`. No annotation needed.

  ## Plural-association semantics

  When multiple predicates filter the same plural alias under the same boolean
  connector, they collapse into one EXISTS subquery:

  - `comments.spam == false AND comments.body contains "ship"` — one EXISTS,
    both predicates AND-ed inside.
  - `comments.spam == false OR comments.body contains "ship"` — one EXISTS,
    predicates OR-ed inside.
  - Predicates on different plural aliases produce separate EXISTS clauses.

  v1 restriction: a plural association may only appear as the first segment
  of a dotted path. `comments.author.name` is allowed; `author.comments.body`
  returns an error.

  Returns `{:ok, query}` or `{:error, reason}`. Parse failures return
  `{:error, %EctoQueryParser.ParseError{}}` (with line/column position
  information); builder and validation errors return `{:error, binary}`.
  """
  def apply(queryable, query_string, opts \\ []) do
    schema = extract_schema(queryable)
    builder_opts = if schema, do: Keyword.put(opts, :schema, schema), else: opts

    query = ensure_source_binding(Ecto.Queryable.to_query(queryable))
    source_binding = query.from.as
    builder_opts = Keyword.put(builder_opts, :source_binding, source_binding)

    params = Keyword.get(opts, :params, %{})

    with {:ok, ast} <- parse(query_string),
         {:ok, pruned} <- EctoQueryParser.Params.prune(ast, params),
         {:ok, rewritten} <- EctoQueryParser.ExistsRewriter.rewrite(pruned, builder_opts),
         {:ok, dynamic_expr, joins} <- EctoQueryParser.Builder.build(rewritten, builder_opts) do
      query =
        query
        |> EctoQueryParser.Joins.apply(joins)
        |> where(^dynamic_expr)

      {:ok, query}
    end
  end

  @doc """
  Parses a pipe query string into an `EctoQueryParser.Pipe.Query` struct.

  A pipe query is a source (a table name like `orders` / `sales.orders`, or
  an external `@slug` reference) followed by zero or more `|`-separated
  stages:

      orders
      | filter status == "paid" AND amount >= {{min_amount}}
      | group customer.region { total = sum(amount), n = count() }
      | sort -total
      | limit 10

  Whitespace (including newlines) is insignificant around `|`; a bare source
  with no stages is a valid query. The `filter` stage embeds the plain
  filter grammar verbatim, parameters and `[[optional]]` groups included.

  Parsing performs no validation against a schema or field spec — use
  `build_pipe/2` for that. The returned struct exposes the query's `:source`
  so callers can validate the referenced table before building.

  Returns `{:ok, %EctoQueryParser.Pipe.Query{}}` or
  `{:error, %EctoQueryParser.ParseError{}}`.
  """
  def parse_pipe(query_string) when is_binary(query_string) do
    EctoQueryParser.Pipe.Parser.parse(query_string)
  end

  @doc """
  Parses and compiles a pipe query into an Ecto query.

  Accepts a pipe query string or an already-parsed
  `EctoQueryParser.Pipe.Query` struct. Returns `{:ok, query, columns}` or
  `{:error, reason}`, where `reason` is an `EctoQueryParser.ParseError`
  (parse failures), an `EctoQueryParser.ValidationError` (stage-level
  validation failures, positioned when the offending token's location is
  known), or a plain binary (errors arising inside a `filter` stage's
  boolean expression, prefixed with the stage that produced them).

  ## Output columns

  Aggregation and select aliases come from untrusted input, so they are
  never turned into atoms. Instead, every projection stage (`select` /
  `group`) selects into positional atom keys `:c0`, `:c1`, … (a fixed,
  compile-time set; at most 64 columns per stage) and `columns` returns the
  mapping back to the user-facing names, in output order:

      {:ok, query, columns} =
        EctoQueryParser.build_pipe(
          "orders | group region { total = sum(amount) } | sort -total")

      columns
      #=> [%{name: "region", key: :c0}, %{name: "total", key: :c1}]

      Repo.all(query)
      #=> [%{c0: "north", c1: 1200}, ...]

  Rows come back keyed by the positional atoms; rename them with `columns`.
  When the pipe has no projection stage (bare source, or filter/sort/limit
  only), the query keeps the source's own row shape and `columns` is `nil` —
  note that a schemaless table source then has no select clause at all, so
  attach one (`query |> select(...)`) before executing.

  ## Sources

  A table source compiles to a schemaless `from` (optionally
  schema-qualified: `sales.orders` sets the query prefix). The table name is
  **not** validated — parse first with `parse_pipe/1` and check the struct's
  `:source` against your catalog, then pass the matching `:allowed_fields`.

  An `@slug` source is resolved through the required `:resolve_source`
  option:

      resolve_source: fn slug ->
        case MyApp.Questions.fetch(slug) do
          {:ok, question} -> {:ok, question.query, question.fields}
          :error -> {:error, "no such question"}
        end
      end

  The resolver receives the slug (without the `@`) and must return
  `{:ok, queryable, fields}` — the queryable is inlined as a subquery
  source, and `fields` is its output field spec in the same format as
  `:allowed_fields` (so stages can be validated and typed against it) — or
  `{:error, message}`. The queryable must be usable as an Ecto subquery
  (i.e. carry a select, as any schema-based or previously-built query
  does). A `@slug` in the text without a `:resolve_source` option is a
  build error.

  ## Options

    * `:allowed_fields` — field spec for a table source, exactly as in
      `apply/3` (allowlisting, types for coercion, association tuples for
      schemaless joins/EXISTS).
    * `:params` — `{{name}}` parameter bindings for filter stages.
    * `:literal_transform` — the same hook as in `apply/3`; applies inside
      filter stages, including filters over grouped output (where breakout
      columns keep their underlying type and aggregation aliases get the
      aggregate's type).
    * `:resolve_source` — resolver for `@slug` sources (see above).

  Row capping remains the caller's job: `limit`/`offset` stages are applied
  as written, and a caller-enforced hard cap should be applied to the
  returned query as today.
  """
  def build_pipe(query, opts \\ [])

  def build_pipe(query_string, opts) when is_binary(query_string) do
    with {:ok, pipe} <- parse_pipe(query_string) do
      build_pipe(pipe, opts)
    end
  end

  def build_pipe(%EctoQueryParser.Pipe.Query{} = pipe, opts) do
    EctoQueryParser.Pipe.Compiler.compile(pipe, opts)
  end

  @doc """
  Lists the `{{name}}` parameters referenced by a filter string or a pipe
  query string, in order of first appearance.

  Each entry is `%{name: String.t(), required: boolean()}`. A parameter is
  optional (`required: false`) iff **every** occurrence of its name sits
  inside an `[[ ... ]]` optional group.

      iex> EctoQueryParser.parameters("status == {{status}} [[AND created_at >= {{start}}]]")
      {:ok, [%{name: "status", required: true}, %{name: "start", required: false}]}

  Pipe queries are supported — parameters may appear in any `filter` stage:

      iex> EctoQueryParser.parameters("orders | filter status == {{status}} | limit 5")
      {:ok, [%{name: "status", required: true}]}

  Also accepts an already-parsed `EctoQueryParser.Pipe.Query`.

  Returns `{:error, %EctoQueryParser.ParseError{}}` if the string parses
  neither as a filter nor as a pipe query (whichever parse consumed more
  input provides the error).
  """
  def parameters(query_string) when is_binary(query_string) do
    case parse(query_string) do
      {:ok, ast} ->
        {:ok, EctoQueryParser.Params.list(ast)}

      {:error, filter_error} ->
        case parse_pipe(query_string) do
          {:ok, pipe} ->
            parameters(pipe)

          {:error, pipe_error} ->
            if pipe_error.byte_offset > filter_error.byte_offset,
              do: {:error, pipe_error},
              else: {:error, filter_error}
        end
    end
  end

  def parameters(%EctoQueryParser.Pipe.Query{stages: stages}) do
    entries =
      for {:filter, ast, _pos} <- stages,
          entry <- EctoQueryParser.Params.list(ast),
          do: entry

    params =
      entries
      |> Enum.map(& &1.name)
      |> Enum.uniq()
      |> Enum.map(fn name ->
        %{name: name, required: Enum.any?(entries, &(&1.name == name and &1.required))}
      end)

    {:ok, params}
  end

  # Names the source binding so EXISTS subqueries can reference it via
  # `parent_as(^name)`. If the user already named the source, keep theirs;
  # otherwise patch in `:__eqp_source`. Updates both `from.as` and the
  # `aliases` registry — Ecto looks up named bindings in the latter.
  defp ensure_source_binding(%Ecto.Query{from: %{as: nil} = from, aliases: aliases} = query) do
    %{query | from: %{from | as: :__eqp_source}, aliases: Map.put(aliases, :__eqp_source, 0)}
  end

  defp ensure_source_binding(%Ecto.Query{} = query), do: query

  defp extract_schema(module) when is_atom(module) do
    (Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) and module) || nil
  end

  defp extract_schema(%Ecto.Query{from: %{source: {_, schema}}})
       when is_atom(schema) and not is_nil(schema) do
    schema
  end

  defp extract_schema(_), do: nil
end
