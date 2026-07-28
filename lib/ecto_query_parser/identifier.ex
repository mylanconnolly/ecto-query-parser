defmodule EctoQueryParser.Identifier do
  @moduledoc false

  # Classifies dotted identifiers as singular (regular field, JSONB,
  # belongs_to/has_one chain) or plural (has_many, many_to_many) so the EXISTS
  # rewriter knows whether to wrap a leaf in an :exists node.
  #
  # A "plural" classification means the first segment of the identifier
  # references a has_many or many_to_many association and the rest of the
  # path lives inside the EXISTS subquery.

  @doc """
  Classify the first segment of a dotted identifier name.

  Returns one of:
    * `:singular` — identifier has no plural references at any depth.
    * `{:plural, binding, kind, aopts, inner_path, sub_opts}` — the first
      segment is a has_many / many_to_many association. `inner_path` is the
      remainder of the dotted path (joined by ".") that lives inside the
      EXISTS, and `sub_opts` is the opts keyword list to use when recursively
      building the inner predicate (either `[allowed_fields: ...]` or
      `[schema: ...]`).
    * `{:error, reason}` — invalid identifier (e.g., plural appearing after a
      singular segment, which is not supported in v1).
  """
  def classify(name, opts) when is_binary(name) do
    case String.split(name, ".") do
      [_only] -> :singular
      [first | rest] -> classify_segments(first, rest, opts)
    end
  end

  defp classify_segments(first, rest, opts) do
    case lookup(first, opts) do
      {:plural, kind, aopts, sub_opts} ->
        # Safe: lookup/2 above only classifies as plural when the segment
        # resolved via String.to_existing_atom/1, so this cannot create atoms.
        {:plural, String.to_existing_atom(first), kind, aopts, Enum.join(rest, "."), sub_opts}

      {:singular, _kind, sub_opts} ->
        case ensure_no_plural(rest, sub_opts, first) do
          :ok -> :singular
          {:error, _} = err -> err
        end

      :not_assoc ->
        case ensure_no_plural(rest, opts, first) do
          :ok -> :singular
          {:error, _} = err -> err
        end
    end
  end

  defp ensure_no_plural([], _opts, _trail), do: :ok
  defp ensure_no_plural([_leaf], _opts, _trail), do: :ok

  defp ensure_no_plural([next | rest], opts, trail) do
    case lookup(next, opts) do
      {:plural, _kind, _aopts, _sub_opts} ->
        {:error,
         "plural association `#{next}` is only supported as the first segment of " <>
           "a dotted path (got `#{trail}.#{next}.#{Enum.join(rest, ".")}`). " <>
           "Filter through it directly instead."}

      {:singular, _kind, sub_opts} ->
        ensure_no_plural(rest, sub_opts, trail <> "." <> next)

      :not_assoc ->
        ensure_no_plural(rest, opts, trail <> "." <> next)
    end
  end

  # Lookup a segment string against the active context.
  defp lookup(segment, opts) when is_binary(segment) do
    case safe_to_atom(segment) do
      {:ok, atom} ->
        case Keyword.fetch(opts, :schema) do
          {:ok, schema} -> lookup_schema(atom, schema)
          :error -> lookup_allowed_fields(atom, opts)
        end

      :error ->
        :not_assoc
    end
  end

  defp lookup_schema(atom, schema) do
    case schema.__schema__(:association, atom) do
      nil ->
        :not_assoc

      %Ecto.Association.BelongsTo{queryable: queryable} ->
        {:singular, :belongs_to, [schema: queryable]}

      %Ecto.Association.Has{cardinality: :one, queryable: queryable} ->
        {:singular, :has_one, [schema: queryable]}

      %Ecto.Association.Has{
        cardinality: :many,
        owner_key: owner_key,
        related_key: related_key,
        queryable: queryable
      } ->
        aopts = %{
          kind: :has_many,
          table: source_table(queryable),
          owner_key: owner_key,
          related_key: related_key,
          prefix: nil
        }

        {:plural, :has_many, aopts, [schema: queryable]}

      %Ecto.Association.ManyToMany{
        owner_key: owner_key,
        queryable: queryable,
        join_through: join_through,
        join_keys: [{join_owner_key, _}, {join_related_key, related_key}]
      } ->
        aopts = %{
          kind: :many_to_many,
          table: source_table(queryable),
          owner_key: owner_key,
          related_key: related_key,
          join_through: join_source(join_through),
          join_owner_key: join_owner_key,
          join_related_key: join_related_key,
          prefix: nil,
          join_prefix: nil
        }

        {:plural, :many_to_many, aopts, [schema: queryable]}
    end
  end

  defp lookup_allowed_fields(atom, opts) do
    case Keyword.fetch(opts, :allowed_fields) do
      :error ->
        :not_assoc

      {:ok, allowed} when is_list(allowed) ->
        if Keyword.keyword?(allowed) do
          allowed
          |> Keyword.get(atom)
          |> classify_allowed_value()
        else
          :not_assoc
        end

      _ ->
        :not_assoc
    end
  end

  defp classify_allowed_value({:assoc, ao}), do: belongs_to_singular(ao)
  defp classify_allowed_value({:belongs_to, ao}), do: belongs_to_singular(ao)
  defp classify_allowed_value({:has_many, ao}), do: has_many_plural(ao)
  defp classify_allowed_value({:many_to_many, ao}), do: m2m_plural(ao)
  defp classify_allowed_value(_), do: :not_assoc

  defp belongs_to_singular(ao) do
    sub_opts = [allowed_fields: Keyword.get(ao, :fields, [])]
    {:singular, :belongs_to, sub_opts}
  end

  defp has_many_plural(ao) do
    aopts = %{
      kind: :has_many,
      table: Keyword.fetch!(ao, :table),
      owner_key: Keyword.fetch!(ao, :owner_key),
      related_key: Keyword.fetch!(ao, :related_key),
      prefix: Keyword.get(ao, :prefix)
    }

    sub_opts = [allowed_fields: Keyword.get(ao, :fields, [])]
    {:plural, :has_many, aopts, sub_opts}
  end

  defp m2m_plural(ao) do
    aopts = %{
      kind: :many_to_many,
      table: Keyword.fetch!(ao, :table),
      owner_key: Keyword.fetch!(ao, :owner_key),
      related_key: Keyword.fetch!(ao, :related_key),
      join_through: join_source(Keyword.fetch!(ao, :join_through)),
      join_owner_key: Keyword.fetch!(ao, :join_owner_key),
      join_related_key: Keyword.fetch!(ao, :join_related_key),
      prefix: Keyword.get(ao, :prefix),
      join_prefix: Keyword.get(ao, :join_prefix)
    }

    sub_opts = [allowed_fields: Keyword.get(ao, :fields, [])]
    {:plural, :many_to_many, aopts, sub_opts}
  end

  defp source_table(queryable) when is_atom(queryable), do: queryable.__schema__(:source)

  defp join_source(table) when is_binary(table), do: table
  defp join_source(module) when is_atom(module), do: module.__schema__(:source)

  defp safe_to_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end
end
