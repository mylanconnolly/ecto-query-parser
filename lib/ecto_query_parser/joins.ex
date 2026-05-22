defmodule EctoQueryParser.Joins do
  @moduledoc false

  # Applies a list of join specs (schemaless or schema-based) to a query,
  # deduplicating by binding name. Extracted from `EctoQueryParser` so both
  # the top-level WHERE application and the EXISTS subquery construction in
  # `EctoQueryParser.Builder` can share the same logic.
  #
  # Join spec shapes:
  #
  #   - schemaless belongs-to:
  #     %{binding: atom, table: String.t(), owner_key: atom, related_key: atom,
  #       parent: :root | atom, prefix: nil | String.t()}
  #
  #   - schema-based:
  #     %{binding: atom, assoc: atom, parent: :root | atom}

  import Ecto.Query

  def apply(queryable, joins) do
    joins
    |> Enum.uniq_by(& &1.binding)
    |> Enum.reduce(queryable, fn join_spec, query ->
      if has_named_binding?(query, join_spec.binding) do
        query
      else
        apply_one(query, join_spec)
      end
    end)
  end

  # Schemaless join from root.
  defp apply_one(query, %{
         binding: binding,
         table: table,
         owner_key: ok,
         related_key: rk,
         parent: :root
       } = spec) do
    prefix = Map.get(spec, :prefix)

    if prefix do
      join(query, :left, [row], related in ^table,
        on: field(related, ^rk) == field(row, ^ok),
        as: ^binding,
        prefix: ^prefix
      )
    else
      from(row in query,
        left_join: related in ^table,
        on: field(related, ^rk) == field(row, ^ok),
        as: ^binding
      )
    end
  end

  # Schemaless join from a named parent.
  defp apply_one(query, %{
         binding: binding,
         table: table,
         owner_key: ok,
         related_key: rk,
         parent: parent
       } = spec) do
    prefix = Map.get(spec, :prefix)

    if prefix do
      join(query, :left, [{^parent, p}], related in ^table,
        on: field(related, ^rk) == field(p, ^ok),
        as: ^binding,
        prefix: ^prefix
      )
    else
      from([{^parent, p}] in query,
        left_join: related in ^table,
        on: field(related, ^rk) == field(p, ^ok),
        as: ^binding
      )
    end
  end

  # Schema-based join from root.
  defp apply_one(query, %{binding: binding, assoc: assoc, parent: :root}) do
    from(row in query,
      left_join: related in assoc(row, ^assoc),
      as: ^binding
    )
  end

  # Schema-based join from a named parent.
  defp apply_one(query, %{binding: binding, assoc: assoc, parent: parent}) do
    from([{^parent, p}] in query,
      left_join: related in assoc(p, ^assoc),
      as: ^binding
    )
  end
end
