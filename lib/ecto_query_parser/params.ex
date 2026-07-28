defmodule EctoQueryParser.Params do
  @moduledoc false

  # AST-level support for `{{name}}` parameters and `[[ ... ]]` optional
  # groups:
  #
  #   * `prune/2` removes optional groups whose parameters are not all bound
  #     and splices the surviving groups' contents into their parent
  #     connector chains. Runs after parse and before the ExistsRewriter /
  #     Builder.
  #   * `substitute/2` replaces every `{:param, name}` node with the literal
  #     node for its bound value, so the Builder sees the exact AST it would
  #     have seen had the value been written inline. Unbound parameters are
  #     a build error.
  #   * `list/1` walks a parsed AST and reports each parameter (in order of
  #     first appearance) with a `required` flag — false iff every occurrence
  #     of the name sits inside an optional group.
  #
  # SECURITY: parameter names stay plain strings throughout. Binding looks
  # names up against the caller-supplied params map (string keys, with an
  # existing-atom fallback for atom-keyed maps) — no code path here creates
  # atoms from input.

  @doc """
  Prune optional groups whose parameters are not all bound.

  Bound groups splice their contents into the surrounding connector list, as
  if the brackets were absent. If pruning removes the entire expression, the
  neutral `{:boolean, true}` AST is returned.
  """
  def prune(ast, params) do
    case do_prune(ast, params) do
      :empty -> {:ok, {:boolean, true}}
      pruned -> {:ok, pruned}
    end
  end

  defp do_prune({:and, items}, params), do: prune_chain(:and, items, params)
  defp do_prune({:or, items}, params), do: prune_chain(:or, items, params)

  defp do_prune({:not, inner}, params) do
    case do_prune(inner, params) do
      :empty -> :empty
      pruned -> {:not, pruned}
    end
  end

  # A group standing alone (e.g. `[[status == {{s}}]]` as the whole filter).
  defp do_prune({:optional, connector, items}, params) do
    if group_bound?(items, params) do
      case items do
        [single] -> single
        many -> {connector, many}
      end
    else
      :empty
    end
  end

  defp do_prune(other, _params), do: other

  defp prune_chain(connector, items, params) do
    kept =
      Enum.flat_map(items, fn
        {:optional, _connector, sub_items} ->
          if group_bound?(sub_items, params), do: sub_items, else: []

        item ->
          case do_prune(item, params) do
            :empty -> []
            pruned -> [pruned]
          end
      end)

    case kept do
      [] -> :empty
      [single] -> single
      many -> {connector, many}
    end
  end

  defp group_bound?(items, params) do
    items
    |> Enum.flat_map(&collect_param_names/1)
    |> Enum.all?(&bound?(&1, params))
  end

  @doc """
  Replace every `{:param, name}` node with the literal node for its bound
  value. Returns `{:error, "missing required parameter: name"}` for the first
  unbound parameter encountered.
  """
  def substitute(ast, params) do
    do_substitute(ast, params)
  catch
    {:missing_param, name} -> {:error, "missing required parameter: #{name}"}
  end

  defp do_substitute(ast, params), do: {:ok, walk_substitute(ast, params)}

  defp walk_substitute({:param, name}, params) do
    case fetch(name, params) do
      {:ok, value} when not is_nil(value) -> value_to_node(value)
      _ -> throw({:missing_param, name})
    end
  end

  defp walk_substitute({:and, items}, params),
    do: {:and, Enum.map(items, &walk_substitute(&1, params))}

  defp walk_substitute({:or, items}, params),
    do: {:or, Enum.map(items, &walk_substitute(&1, params))}

  defp walk_substitute({:optional, connector, items}, params),
    do: {:optional, connector, Enum.map(items, &walk_substitute(&1, params))}

  defp walk_substitute({:not, inner}, params), do: {:not, walk_substitute(inner, params)}

  defp walk_substitute({:op, op, left, right}, params),
    do: {:op, op, walk_substitute(left, params), walk_substitute(right, params)}

  defp walk_substitute({:between, target, low, high}, params) do
    {:between, walk_substitute(target, params), walk_substitute(low, params),
     walk_substitute(high, params)}
  end

  defp walk_substitute({:is_null, expr}, params), do: {:is_null, walk_substitute(expr, params)}

  defp walk_substitute({:is_not_null, expr}, params),
    do: {:is_not_null, walk_substitute(expr, params)}

  defp walk_substitute({:function, name, args}, params),
    do: {:function, name, Enum.map(args, &walk_substitute(&1, params))}

  defp walk_substitute({:list, items}, params),
    do: {:list, Enum.map(items, &walk_substitute(&1, params))}

  # Synthetic node emitted by the ExistsRewriter: substitute inside the
  # subquery's AST as well, so params work in plural-association predicates.
  defp walk_substitute({:exists, binding, kind, aopts, inner, sub_opts}, params),
    do: {:exists, binding, kind, aopts, walk_substitute(inner, params), sub_opts}

  defp walk_substitute(other, _params), do: other

  # Bound values behave exactly like literals of that value, so tag them with
  # the same AST nodes the parser would have produced. Values without a
  # literal syntax (Date, DateTime, Decimal, ...) become {:value, term},
  # which the Builder pins directly.
  defp value_to_node(v) when is_boolean(v), do: {:boolean, v}
  defp value_to_node(v) when is_binary(v), do: {:string, v}
  defp value_to_node(v) when is_integer(v), do: {:integer, v}
  defp value_to_node(v) when is_float(v), do: {:float, v}
  defp value_to_node(v) when is_list(v), do: {:list, Enum.map(v, &value_to_node/1)}
  defp value_to_node(v), do: {:value, v}

  @doc """
  List the parameters referenced by a parsed AST, in order of first
  appearance. Each entry is `%{name: String.t(), required: boolean()}`;
  `required` is false iff every occurrence of the name sits inside an
  optional group.
  """
  def list(ast) do
    occurrences = collect_occurrences(ast, false)

    occurrences
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.map(fn name ->
      required = Enum.any?(occurrences, fn {n, optional} -> n == name and not optional end)
      %{name: name, required: required}
    end)
  end

  defp collect_param_names(ast) do
    ast |> collect_occurrences(false) |> Enum.map(&elem(&1, 0))
  end

  defp collect_occurrences({:param, name}, optional?), do: [{name, optional?}]

  defp collect_occurrences({:optional, _connector, items}, _optional?),
    do: Enum.flat_map(items, &collect_occurrences(&1, true))

  defp collect_occurrences({:and, items}, optional?),
    do: Enum.flat_map(items, &collect_occurrences(&1, optional?))

  defp collect_occurrences({:or, items}, optional?),
    do: Enum.flat_map(items, &collect_occurrences(&1, optional?))

  defp collect_occurrences({:not, inner}, optional?), do: collect_occurrences(inner, optional?)

  defp collect_occurrences({:op, _op, left, right}, optional?),
    do: collect_occurrences(left, optional?) ++ collect_occurrences(right, optional?)

  defp collect_occurrences({:between, target, low, high}, optional?) do
    collect_occurrences(target, optional?) ++
      collect_occurrences(low, optional?) ++ collect_occurrences(high, optional?)
  end

  defp collect_occurrences({:is_null, expr}, optional?), do: collect_occurrences(expr, optional?)

  defp collect_occurrences({:is_not_null, expr}, optional?),
    do: collect_occurrences(expr, optional?)

  defp collect_occurrences({:function, _name, args}, optional?),
    do: Enum.flat_map(args, &collect_occurrences(&1, optional?))

  defp collect_occurrences({:list, items}, optional?),
    do: Enum.flat_map(items, &collect_occurrences(&1, optional?))

  defp collect_occurrences({:exists, _b, _k, _a, inner, _s}, optional?),
    do: collect_occurrences(inner, optional?)

  defp collect_occurrences(_other, _optional?), do: []

  # --- Params map access ---

  defp bound?(name, params) do
    case fetch(name, params) do
      {:ok, value} -> not is_nil(value)
      :error -> false
    end
  end

  # String keys are the documented shape; atom keys are accepted as a
  # convenience. The atom lookup goes through String.to_existing_atom/1 —
  # if the atom does not already exist, the map cannot contain it as a key,
  # so hostile parameter names never create atoms.
  defp fetch(name, params) when is_map(params) do
    case Map.fetch(params, name) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case existing_atom(name) do
          {:ok, atom} -> Map.fetch(params, atom)
          :error -> :error
        end
    end
  end

  defp fetch(_name, _params), do: :error

  defp existing_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end
end
