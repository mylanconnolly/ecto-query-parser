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
      associations can be defined directly in `allowed_fields` using `{:assoc, opts}` tuples:

          allowed_fields: [
            name: :string,
            author: {:assoc,
              table: "users",
              owner_key: :author_id,
              related_key: :id,
              fields: [name: :string, email: :string]}
          ]

      Association options:
        - `:table` — target table name (string, required)
        - `:owner_key` — FK on the source table (atom, required)
        - `:related_key` — PK on the target table (atom, required)
        - `:fields` — keyword list of available fields, supports nesting (optional,
          defaults to `[]` meaning all fields allowed)

      When a schema IS available, it takes priority (fully backward compatible).

  Returns `{:ok, query}` or `{:error, reason}`.
  """
  def apply(queryable, query_string, opts \\ []) do
    schema = extract_schema(queryable)
    builder_opts = if schema, do: Keyword.put(opts, :schema, schema), else: opts

    with {:ok, ast} <- parse(query_string),
         {:ok, dynamic_expr, joins} <- EctoQueryParser.Builder.build(ast, builder_opts) do
      query =
        queryable
        |> apply_joins(joins)
        |> where(^dynamic_expr)

      {:ok, query}
    end
  end

  defp extract_schema(module) when is_atom(module) do
    (Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) and module) || nil
  end

  defp extract_schema(%Ecto.Query{from: %{source: {_, schema}}})
       when is_atom(schema) and not is_nil(schema) do
    schema
  end

  defp extract_schema(_), do: nil

  defp apply_joins(queryable, joins) do
    joins
    |> deduplicate_joins()
    |> Enum.reduce(queryable, fn join_spec, query ->
      if has_named_binding?(query, join_spec.binding) do
        query
      else
        apply_single_join(query, join_spec)
      end
    end)
  end

  defp deduplicate_joins(joins) do
    joins
    |> Enum.uniq_by(& &1.binding)
  end

  # Schemaless joins: pattern match on :table key
  defp apply_single_join(query, %{
         binding: binding,
         table: table,
         owner_key: ok,
         related_key: rk,
         parent: :root
       }) do
    from(row in query,
      left_join: related in ^table,
      on: field(related, ^rk) == field(row, ^ok),
      as: ^binding
    )
  end

  defp apply_single_join(query, %{
         binding: binding,
         table: table,
         owner_key: ok,
         related_key: rk,
         parent: parent
       }) do
    from([{^parent, p}] in query,
      left_join: related in ^table,
      on: field(related, ^rk) == field(p, ^ok),
      as: ^binding
    )
  end

  # Schema-based joins: pattern match on :assoc key
  defp apply_single_join(query, %{binding: binding, assoc: assoc, parent: :root}) do
    from(row in query,
      left_join: related in assoc(row, ^assoc),
      as: ^binding
    )
  end

  defp apply_single_join(query, %{binding: binding, assoc: assoc, parent: parent}) do
    from([{^parent, p}] in query,
      left_join: related in assoc(p, ^assoc),
      as: ^binding
    )
  end
end
