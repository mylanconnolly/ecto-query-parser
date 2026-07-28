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

  ## Options

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

    with {:ok, ast} <- parse(query_string),
         {:ok, rewritten} <- EctoQueryParser.ExistsRewriter.rewrite(ast, builder_opts),
         {:ok, dynamic_expr, joins} <- EctoQueryParser.Builder.build(rewritten, builder_opts) do
      query =
        query
        |> EctoQueryParser.Joins.apply(joins)
        |> where(^dynamic_expr)

      {:ok, query}
    end
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
