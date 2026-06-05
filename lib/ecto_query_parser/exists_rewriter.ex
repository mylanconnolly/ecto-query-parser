defmodule EctoQueryParser.ExistsRewriter do
  @moduledoc false

  # AST pre-pass that walks the parsed AST and wraps leaves referencing
  # has_many / many_to_many associations in a synthetic
  #
  #     {:exists, binding, kind, aopts, inner_ast, sub_opts}
  #
  # node. Within a single boolean combinator ({:and, _} or {:or, _}),
  # exists-nodes sharing the same `binding` are merged into one — their inner
  # ASTs are combined with that combinator. This implements §4 of the
  # relationship support spec:
  #
  #   - same alias under AND → one EXISTS with both predicates AND-ed
  #   - same alias under OR  → one EXISTS with predicates OR-ed
  #   - different aliases    → separate EXISTS clauses
  #
  # Identifiers inside the EXISTS subquery have the leading plural segment
  # stripped (e.g., `comments.body` → `body`, `comments.author.name` →
  # `author.name`), so the recursive Builder call inside the EXISTS clause
  # sees a normal path it can resolve against the nested context.

  alias EctoQueryParser.Identifier

  @doc """
  Rewrite an AST so plural-reference leaves become `{:exists, ...}` nodes.
  Returns `{:ok, ast}` or `{:error, reason}`.
  """
  def rewrite(ast, opts), do: do_rewrite(ast, opts)

  defp do_rewrite({:and, items}, opts), do: rewrite_combinator(:and, items, opts)
  defp do_rewrite({:or, items}, opts), do: rewrite_combinator(:or, items, opts)
  defp do_rewrite({:op, _, _, _} = leaf, opts), do: wrap_leaf(leaf, opts)
  defp do_rewrite(other, _opts), do: {:ok, other}

  defp rewrite_combinator(combinator, items, opts) do
    case map_ok(items, &do_rewrite(&1, opts)) do
      {:ok, rewritten} ->
        merged = merge_same_binding(rewritten, combinator)

        case merged do
          [single] -> {:ok, single}
          many -> {:ok, {combinator, many}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp wrap_leaf({:op, op, left, right} = leaf, opts) do
    with {:ok, left_class} <- classify_operand(left, opts),
         {:ok, right_class} <- classify_operand(right, opts) do
      case {left_class, right_class} do
        {:singular, :singular} ->
          {:ok, leaf}

        {{:plural, binding, kind, aopts, sub_opts}, :singular} ->
          inner_left = strip_first_segment(left)
          {:ok, {:exists, binding, kind, aopts, {:op, op, inner_left, right}, sub_opts}}

        {:singular, {:plural, binding, kind, aopts, sub_opts}} ->
          inner_right = strip_first_segment(right)
          {:ok, {:exists, binding, kind, aopts, {:op, op, left, inner_right}, sub_opts}}

        {{:plural, _, _, _, _}, {:plural, _, _, _, _}} ->
          {:error, "comparison referencing a plural association on both sides is not supported"}
      end
    end
  end

  defp classify_operand({:identifier, name}, opts) do
    case Identifier.classify(name, opts) do
      :singular ->
        {:ok, :singular}

      {:plural, binding, kind, aopts, _inner_path, sub_opts} ->
        {:ok, {:plural, binding, kind, aopts, sub_opts}}

      {:error, _} = err ->
        err
    end
  end

  defp classify_operand(_other, _opts), do: {:ok, :singular}

  defp strip_first_segment({:identifier, name}) do
    [_first | rest] = String.split(name, ".")
    {:identifier, Enum.join(rest, ".")}
  end

  # Single-pass merge that preserves source order. When a second
  # {:exists, B, ...} is encountered for binding B already in the accumulator,
  # combine its inner AST with the existing one using `combinator`.
  defp merge_same_binding(items, combinator) do
    Enum.reduce(items, [], fn item, acc ->
      case item do
        {:exists, b, _, _, _, _} ->
          case find_index_by_binding(acc, b) do
            nil ->
              acc ++ [item]

            idx ->
              {:exists, ^b, kind, aopts, existing_inner, sub_opts} = Enum.at(acc, idx)
              {:exists, ^b, _, _, new_inner, _} = item
              merged_inner = combine_inner(existing_inner, new_inner, combinator)
              merged = {:exists, b, kind, aopts, merged_inner, sub_opts}
              List.replace_at(acc, idx, merged)
          end

        _ ->
          acc ++ [item]
      end
    end)
  end

  defp find_index_by_binding(items, binding) do
    Enum.find_index(items, fn
      {:exists, b, _, _, _, _} -> b == binding
      _ -> false
    end)
  end

  # Append into an existing combinator if it matches, else create one.
  defp combine_inner({comb, list}, new, comb), do: {comb, list ++ [new]}
  defp combine_inner(existing, new, comb), do: {comb, [existing, new]}

  defp map_ok(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, v} -> {:cont, {:ok, [v | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      err -> err
    end
  end
end
