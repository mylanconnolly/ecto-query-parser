defmodule EctoQueryParser.Builder do
  @moduledoc """
  Converts parsed AST nodes into Ecto dynamic expressions.
  """

  import Ecto.Query

  @function_names %{
    "to_upper" => "UPPER",
    "upper" => "UPPER",
    "to_lower" => "LOWER",
    "lower" => "LOWER",
    "trim" => "TRIM",
    "length" => "LENGTH",
    "coalesce" => "COALESCE",
    "left" => "LEFT",
    "right" => "RIGHT",
    "substring" => "SUBSTRING",
    "concat" => "CONCAT",
    "abs" => "ABS",
    "floor" => "FLOOR",
    "ceil" => "CEIL",
    "add_interval" => "ADD_INTERVAL",
    "sub_interval" => "SUB_INTERVAL",
    "replace" => "REPLACE"
  }

  @date_trunc_functions %{
    "round_second" => "second",
    "round_minute" => "minute",
    "round_hour" => "hour",
    "round_day" => "day",
    "round_week" => "week",
    "round_month" => "month",
    "round_quarter" => "quarter",
    "round_year" => "year"
  }

  @doc """
  Builds an Ecto dynamic expression from a parsed AST.

  ## Options

    * `:allowed_fields` - list of atom field names that are permitted.
      If provided, any field not in the list will return an error.
    * `:schema` - the Ecto schema module, needed to resolve dotted identifiers
      (association paths like `author.name`).
    * `:params` - map of `{{name}}` parameter bindings
      (`%{"name" => value}`). Optional groups whose parameters are unbound
      are pruned; any remaining unbound parameter is a build error.
    * `:literal_transform` - `fun(ecto_type, raw_string)` called for string
      literals (and bound string parameter values) compared against a typed
      field, before the built-in coercion. May return `{:ok, term}` (replace
      the value; the transform owns the type), `{:range, {lo, hi}}` (the
      literal denotes an inclusive range; only meaningful for comparison and
      BETWEEN operators), or `:default` (fall through to normal coercion).

  Returns `{:ok, dynamic, joins}` or `{:error, reason}`.
  """
  def build(ast, opts \\ []) do
    params = Keyword.get(opts, :params, %{})

    with {:ok, pruned} <- EctoQueryParser.Params.prune(ast, params),
         {:ok, substituted} <- EctoQueryParser.Params.substitute(pruned, params) do
      to_dynamic(substituted, opts)
    end
  end

  # EXISTS: emitted by EctoQueryParser.ExistsRewriter for has_many /
  # many_to_many references. The inner AST is built against the nested
  # context (`sub_opts`), then wrapped in a correlated subquery. Build-time
  # options that are not tied to the outer context (the literal transform)
  # follow the recursion inside.
  defp to_dynamic({:exists, _binding, kind, aopts, inner_ast, sub_opts}, opts) do
    sub_opts = Keyword.merge(sub_opts, Keyword.take(opts, [:literal_transform]))

    with {:ok, inner_dynamic, inner_joins} <- to_dynamic(inner_ast, sub_opts) do
      source_binding = Keyword.get(opts, :source_binding, :__eqp_source)
      subq = build_exists_subquery(kind, aopts, inner_dynamic, inner_joins, source_binding)
      {:ok, dynamic([_row], exists(subquery(subq))), []}
    end
  end

  # AND: reduce list of conditions with `and`
  defp to_dynamic({:and, [first | rest]}, opts) do
    with {:ok, acc, joins} <- to_dynamic(first, opts) do
      Enum.reduce_while(rest, {:ok, acc, joins}, fn item, {:ok, acc, acc_joins} ->
        case to_dynamic(item, opts) do
          {:ok, d, new_joins} ->
            {:cont, {:ok, dynamic([r], ^acc and ^d), acc_joins ++ new_joins}}

          error ->
            {:halt, error}
        end
      end)
    end
  end

  # OR: reduce list of conditions with `or`
  defp to_dynamic({:or, [first | rest]}, opts) do
    with {:ok, acc, joins} <- to_dynamic(first, opts) do
      Enum.reduce_while(rest, {:ok, acc, joins}, fn item, {:ok, acc, acc_joins} ->
        case to_dynamic(item, opts) do
          {:ok, d, new_joins} ->
            {:cont, {:ok, dynamic([r], ^acc or ^d), acc_joins ++ new_joins}}

          error ->
            {:halt, error}
        end
      end)
    end
  end

  # Comparison operators. Each operand resolves either to a plain expression
  # or — when the :literal_transform option turns a string literal into an
  # inclusive range — to {:range, lo, hi}, which compiles per operator.
  @comparison_ops [:==, :!=, :>=, :<=, :>, :<]

  defp to_dynamic({:op, op, left, right}, opts) when op in @comparison_ops do
    left_type = field_type(left, opts)
    right_type = field_type(right, opts)

    with {:ok, l, lj} <- resolve_operand(left, right_type, opts),
         {:ok, r, rj} <- resolve_operand(right, left_type, opts) do
      compile_comparison(op, l, r, lj ++ rj)
    end
  end

  # NOT: unary logical negation of any inner condition
  defp to_dynamic({:not, inner}, opts) do
    with {:ok, d, joins} <- to_dynamic(inner, opts) do
      {:ok, dynamic([row], not (^d)), joins}
    end
  end

  # IS NULL / IS NOT NULL
  defp to_dynamic({:is_null, expr}, opts) do
    with {:ok, e, joins} <- to_expr(expr, opts) do
      {:ok, dynamic([row], is_nil(^e)), joins}
    end
  end

  defp to_dynamic({:is_not_null, expr}, opts) do
    with {:ok, e, joins} <- to_expr(expr, opts) do
      {:ok, dynamic([row], not is_nil(^e)), joins}
    end
  end

  # IN: membership in a list literal, coercing elements to the field's type.
  # The literal transform runs per string element (against the field's type);
  # a {:range, _} return is not meaningful here and errors.
  defp to_dynamic({:op, :in, left, {:list, items} = right}, opts) do
    element_type = field_type(left, opts)

    element_target =
      case element_type do
        nil -> nil
        type -> {:array, type}
      end

    with {:ok, l, lj} <- to_expr(left, opts),
         {:ok, transformed?, items} <- transform_list_elements(items, element_type, opts),
         {:ok, r, rj} <-
           (if transformed? do
              with {:ok, values} <- literal_values(items) do
                {:ok, dynamic([row], ^values), []}
              end
            else
              to_expr_coerced(right, element_target, opts)
            end) do
      {:ok, dynamic([row], ^l in ^r), lj ++ rj}
    end
  end

  defp to_dynamic({:op, :in, _left, right}, _opts) do
    {:error, "IN operator requires a list value, got: #{inspect(right)}"}
  end

  # BETWEEN: field >= low AND field <= high, coercing both bounds to the
  # target's type the same way == does. When the literal transform turns a
  # bound into a range, each bound resolves independently: the low bound
  # takes its range's lo, the high bound takes its range's hi.
  defp to_dynamic({:between, target, low, high}, opts) do
    target_type = field_type(target, opts)

    with {:ok, t, tj} <- to_expr(target, opts),
         {:ok, lo_res, loj} <- resolve_operand(low, target_type, opts),
         {:ok, hi_res, hij} <- resolve_operand(high, target_type, opts) do
      lo = between_bound(lo_res, :low)
      hi = between_bound(hi_res, :high)
      {:ok, dynamic([row], ^t >= ^lo and ^t <= ^hi), tj ++ loj ++ hij}
    end
  end

  # contains: case-insensitive substring match
  defp to_dynamic({:op, :contains, left, {:string, val}}, opts) do
    with {:ok, l, joins} <- to_expr(left, opts) do
      pattern = "%" <> escape_like(val) <> "%"
      {:ok, dynamic([row], ilike(^l, ^pattern)), joins}
    end
  end

  defp to_dynamic({:op, :contains, left, {:identifier, _} = right}, opts) do
    with {:ok, l, lj} <- to_expr(left, opts),
         {:ok, r, rj} <- to_expr(right, opts) do
      {:ok, dynamic([row], ilike(^l, fragment("'%' || ? || '%'", ^r))), lj ++ rj}
    end
  end

  defp to_dynamic({:op, :contains, _left, right}, _opts) do
    {:error, "contains operator requires a string or identifier value, got: #{inspect(right)}"}
  end

  # like / ilike: pass pattern through directly. The literal transform may
  # replace the pattern via {:ok, term}; a {:range, _} return errors.
  defp to_dynamic({:op, :like, left, right}, opts) do
    with {:ok, l, lj} <- to_expr(left, opts),
         {:ok, r, rj} <- resolve_pattern(right, left, "LIKE", opts) do
      {:ok, dynamic([row], like(^l, ^r)), lj ++ rj}
    end
  end

  defp to_dynamic({:op, :ilike, left, right}, opts) do
    with {:ok, l, lj} <- to_expr(left, opts),
         {:ok, r, rj} <- resolve_pattern(right, left, "ILIKE", opts) do
      {:ok, dynamic([row], ilike(^l, ^r)), lj ++ rj}
    end
  end

  # includes: value in array field
  defp to_dynamic({:op, :includes, left, right}, opts) do
    element_type =
      case field_type(left, opts) do
        {:array, inner} -> inner
        _ -> nil
      end

    with {:ok, l, lj} <- to_expr(left, opts),
         {:ok, r_res, rj} <- resolve_operand(right, element_type, opts),
         {:ok, r} <- expr_only(r_res, "includes") do
      {:ok, dynamic([row], ^r in ^l), lj ++ rj}
    end
  end

  # search: split into words, combine with AND ilike
  defp to_dynamic({:op, :search, left, {:string, val}}, opts) do
    words = PhraseUtils.split(val)

    if words == [] do
      {:ok, dynamic([row], true), []}
    else
      with {:ok, l, joins} <- to_expr(left, opts) do
        conditions =
          Enum.map(words, fn word ->
            pattern = "%" <> escape_like(word) <> "%"
            dynamic([row], ilike(^l, ^pattern))
          end)

        combined = Enum.reduce(conditions, fn d, acc -> dynamic([row], ^acc and ^d) end)
        {:ok, combined, joins}
      end
    end
  end

  defp to_dynamic({:op, :search, _left, right}, _opts) do
    {:error, "search operator requires a string value, got: #{inspect(right)}"}
  end

  # Fallback: try as an expression (standalone values)
  defp to_dynamic(ast, opts), do: to_expr(ast, opts)

  # --- Value-level expressions ---

  defp to_expr({:string, v}, _opts), do: {:ok, dynamic([row], ^v), []}
  defp to_expr({:integer, v}, _opts), do: {:ok, dynamic([row], ^v), []}
  defp to_expr({:float, v}, _opts), do: {:ok, dynamic([row], ^v), []}
  defp to_expr({:boolean, v}, _opts), do: {:ok, dynamic([row], ^v), []}

  # {:value, term} carries a bound parameter value with no literal syntax
  # (Date, DateTime, Decimal, ...); it is pinned directly.
  defp to_expr({:value, v}, _opts), do: {:ok, dynamic([row], ^v), []}

  defp to_expr({:identifier, name}, opts) do
    if String.contains?(name, ".") do
      resolve_dotted_identifier(name, opts)
    else
      with {:ok, atom} <- safe_to_atom(name),
           :ok <- check_allowed_field(atom, opts) do
        {:ok, dynamic([row], field(row, ^atom)), []}
      end
    end
  end

  defp to_expr({:list, items}, _opts) do
    with {:ok, values} <- literal_values(items) do
      {:ok, dynamic([row], ^values), []}
    end
  end

  defp to_expr({:function, "now", []}, _opts) do
    {:ok, dynamic([row], fragment("NOW()")), []}
  end

  defp to_expr({:function, name, [arg]}, opts) do
    case Map.fetch(@date_trunc_functions, name) do
      {:ok, unit} ->
        with {:ok, a, joins} <- to_expr(arg, opts) do
          {:ok, dynamic([row], fragment("DATE_TRUNC(?, ?)", ^unit, ^a)), joins}
        end

      :error ->
        eval_standard_function(name, [arg], opts)
    end
  end

  defp to_expr({:function, name, args}, opts) do
    eval_standard_function(name, args, opts)
  end

  defp eval_standard_function(name, args, opts) do
    case Map.fetch(@function_names, name) do
      {:ok, sql_name} ->
        args
        |> Enum.reduce_while({:ok, [], []}, fn arg, {:ok, acc, acc_joins} ->
          case to_expr(arg, opts) do
            {:ok, d, new_joins} -> {:cont, {:ok, acc ++ [d], acc_joins ++ new_joins}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, evaluated, joins} ->
            case build_fragment(sql_name, evaluated) do
              {:ok, frag} -> {:ok, frag, joins}
              error -> error
            end

          error ->
            error
        end

      :error ->
        {:error, "unknown function: #{name}"}
    end
  end

  # --- Dotted identifier resolution ---

  # SECURITY: dotted identifiers come from untrusted input, so no code path
  # here may create atoms. Allowlist checks compare strings, segment lookups
  # go through `String.to_existing_atom/1`, and JSON path segments stay
  # strings all the way into the `json_extract_path/2` call.
  defp resolve_dotted_identifier(name, opts) do
    with :ok <- check_allowed_field(name, opts) do
      first_segment_str = name |> String.split(".", parts: 2) |> hd()

      case Keyword.fetch(opts, :schema) do
        {:ok, schema} ->
          case existing_atom(first_segment_str) do
            {:ok, first_segment} ->
              if is_json_field?(schema, first_segment) do
                resolve_json_path(first_segment, name, dotted_cast_type(name, opts))
              else
                EctoQueryParser.JoinResolver.resolve(name, schema)
              end

            :error ->
              {:error, "unknown association: #{first_segment_str} on #{inspect(schema)}"}
          end

        :error ->
          resolve_dotted_from_allowed_fields(name, first_segment_str, opts)
      end
    end
  end

  # Cast type for a dotted path from the keyword form of allowed_fields
  # (e.g. `"metadata.count": :integer`). If the dotted atom does not already
  # exist it cannot be an allowed_fields key, so there is no type to find.
  defp dotted_cast_type(name, opts) do
    case existing_atom(name) do
      {:ok, atom} -> get_field_type(atom, opts)
      :error -> nil
    end
  end

  # --- SQL fragment builders ---

  # 1-arg functions
  defp build_fragment("UPPER", [a]), do: {:ok, dynamic([row], fragment("UPPER(?)", ^a))}
  defp build_fragment("LOWER", [a]), do: {:ok, dynamic([row], fragment("LOWER(?)", ^a))}
  defp build_fragment("TRIM", [a]), do: {:ok, dynamic([row], fragment("TRIM(?)", ^a))}
  defp build_fragment("LENGTH", [a]), do: {:ok, dynamic([row], fragment("LENGTH(?)", ^a))}

  defp build_fragment("ABS", [a]), do: {:ok, dynamic([row], fragment("ABS(?)", ^a))}
  defp build_fragment("FLOOR", [a]), do: {:ok, dynamic([row], fragment("FLOOR(?)", ^a))}
  defp build_fragment("CEIL", [a]), do: {:ok, dynamic([row], fragment("CEIL(?)", ^a))}

  # 2-arg functions
  defp build_fragment("COALESCE", [a, b]),
    do: {:ok, dynamic([row], fragment("COALESCE(?, ?)", ^a, ^b))}

  defp build_fragment("LEFT", [a, b]),
    do: {:ok, dynamic([row], fragment("LEFT(?, ?)", ^a, ^b))}

  defp build_fragment("RIGHT", [a, b]),
    do: {:ok, dynamic([row], fragment("RIGHT(?, ?)", ^a, ^b))}

  defp build_fragment("ADD_INTERVAL", [a, b]),
    do: {:ok, dynamic([row], fragment("? + ?::interval", ^a, type(^b, :string)))}

  defp build_fragment("SUB_INTERVAL", [a, b]),
    do: {:ok, dynamic([row], fragment("? - ?::interval", ^a, type(^b, :string)))}

  # 3-arg functions
  defp build_fragment("SUBSTRING", [a, b, c]),
    do: {:ok, dynamic([row], fragment("SUBSTRING(? FROM ? FOR ?)", ^a, ^b, ^c))}

  defp build_fragment("REPLACE", [a, b, c]),
    do: {:ok, dynamic([row], fragment("REPLACE(?, ?, ?)", ^a, ^b, ^c))}

  # CONCAT: variable arity (1-8)
  defp build_fragment("CONCAT", [a]),
    do: {:ok, dynamic([row], fragment("CONCAT(?)", ^a))}

  defp build_fragment("CONCAT", [a, b]),
    do: {:ok, dynamic([row], fragment("CONCAT(?, ?)", ^a, ^b))}

  defp build_fragment("CONCAT", [a, b, c]),
    do: {:ok, dynamic([row], fragment("CONCAT(?, ?, ?)", ^a, ^b, ^c))}

  defp build_fragment("CONCAT", [a, b, c, d]),
    do: {:ok, dynamic([row], fragment("CONCAT(?, ?, ?, ?)", ^a, ^b, ^c, ^d))}

  defp build_fragment("CONCAT", [a, b, c, d, e]),
    do: {:ok, dynamic([row], fragment("CONCAT(?, ?, ?, ?, ?)", ^a, ^b, ^c, ^d, ^e))}

  defp build_fragment("CONCAT", [a, b, c, d, e, f]),
    do: {:ok, dynamic([row], fragment("CONCAT(?, ?, ?, ?, ?, ?)", ^a, ^b, ^c, ^d, ^e, ^f))}

  defp build_fragment("CONCAT", [a, b, c, d, e, f, g]),
    do: {:ok, dynamic([row], fragment("CONCAT(?, ?, ?, ?, ?, ?, ?)", ^a, ^b, ^c, ^d, ^e, ^f, ^g))}

  defp build_fragment("CONCAT", [a, b, c, d, e, f, g, h]),
    do:
      {:ok,
       dynamic([row], fragment("CONCAT(?, ?, ?, ?, ?, ?, ?, ?)", ^a, ^b, ^c, ^d, ^e, ^f, ^g, ^h))}

  defp build_fragment(name, args),
    do: {:error, "unsupported arity for #{name}: got #{length(args)} arguments"}

  # --- Helpers ---

  defp escape_like(string) do
    string
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp safe_to_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, "unknown field: #{name}"}
  end

  # Allowlist checks compare the untrusted name against the (developer
  # supplied) allowed_fields keys as *strings*, so hostile input never
  # creates atoms.
  defp check_allowed_field(atom, opts) when is_atom(atom) do
    check_allowed_field(Atom.to_string(atom), opts)
  end

  defp check_allowed_field(name, opts) when is_binary(name) do
    case Keyword.fetch(opts, :allowed_fields) do
      {:ok, allowed} when is_list(allowed) ->
        if allowed_name?(name, allowed) do
          :ok
        else
          {:error, "field not allowed: #{name}"}
        end

      :error ->
        :ok
    end
  end

  defp allowed_name?(name, allowed) do
    if Keyword.keyword?(allowed) do
      has_string_key?(allowed, name) or nested_field_allowed?(name, allowed)
    else
      Enum.any?(allowed, &(Atom.to_string(&1) == name))
    end
  end

  defp has_string_key?(fields, name) do
    Enum.any?(fields, fn {key, _} -> Atom.to_string(key) == name end)
  end

  defp string_keyword_get(fields, name) do
    Enum.find_value(fields, fn {key, value} ->
      if Atom.to_string(key) == name, do: {:ok, value}
    end)
  end

  defp nested_field_allowed?(name, fields) do
    case String.split(name, ".", parts: 2) do
      [first, rest] ->
        case string_keyword_get(fields, first) do
          {:ok, value} ->
            if singular_assoc?(value) do
              nested_fields = Keyword.get(assoc_opts(value), :fields, [])

              nested_fields == [] or has_string_key?(nested_fields, rest) or
                nested_field_allowed?(rest, nested_fields)
            else
              false
            end

          nil ->
            false
        end

      _ ->
        false
    end
  end

  defp get_field_type(atom, opts) do
    case Keyword.fetch(opts, :allowed_fields) do
      {:ok, allowed} when is_list(allowed) ->
        if Keyword.keyword?(allowed), do: Keyword.get(allowed, atom), else: nil

      :error ->
        nil
    end
  end

  defp resolve_dotted_from_allowed_fields(name, first_segment_str, opts) do
    value =
      case existing_atom(first_segment_str) do
        {:ok, atom} -> get_field_type(atom, opts)
        :error -> nil
      end

    cond do
      value == :map ->
        {:ok, column_atom} = existing_atom(first_segment_str)
        resolve_json_path(column_atom, name, dotted_cast_type(name, opts))

      singular_assoc?(value) ->
        resolve_schemaless_join(name, opts)

      value == nil ->
        {:error,
         "cannot resolve dotted identifier #{name}: " <>
           "no schema available and #{first_segment_str} is not defined in allowed_fields"}

      true ->
        {:error,
         "cannot resolve dotted identifier #{name}: " <>
           "#{first_segment_str} is not an association or map field"}
    end
  end

  defp resolve_schemaless_join(name, opts) do
    segments = String.split(name, ".")
    assoc_segments = Enum.slice(segments, 0..-2//1)
    allowed_fields = Keyword.get(opts, :allowed_fields, [])

    with {:ok, field_name} <- safe_to_atom(List.last(segments)),
         {:ok, joins, final_binding} <-
           walk_schemaless_assocs(assoc_segments, allowed_fields, :root, [], []) do
      expr = dynamic([{^final_binding, x}], field(x, ^field_name))
      {:ok, expr, joins}
    end
  end

  defp walk_schemaless_assocs([], _fields, binding, _path, joins),
    do: {:ok, Enum.reverse(joins), binding}

  defp walk_schemaless_assocs([segment | rest], fields, parent, path, joins) do
    value =
      case existing_atom(segment) do
        {:ok, assoc_atom} -> Keyword.get(fields, assoc_atom)
        :error -> nil
      end

    cond do
      singular_assoc?(value) ->
        assoc_opts = assoc_opts(value)
        new_path = path ++ [segment]
        # Safe: every segment in the path has been validated against the
        # developer-supplied allowed_fields spec, so the binding atom space
        # is bounded by the configured association graph.
        binding = new_path |> Enum.join("__") |> String.to_atom()

        join_spec = %{
          binding: binding,
          table: Keyword.fetch!(assoc_opts, :table),
          owner_key: Keyword.fetch!(assoc_opts, :owner_key),
          related_key: Keyword.fetch!(assoc_opts, :related_key),
          parent: parent,
          prefix: Keyword.get(assoc_opts, :prefix)
        }

        sub_fields = Keyword.get(assoc_opts, :fields, [])
        walk_schemaless_assocs(rest, sub_fields, binding, new_path, [join_spec | joins])

      value == nil ->
        {:error, "unknown association: #{segment}"}

      true ->
        {:error, "#{segment} is not a belongs-to association"}
    end
  end

  defp is_json_field?(schema, field_atom) do
    schema.__schema__(:type, field_atom) == :map
  end

  # The column is an already-validated existing atom; the JSON path segments
  # stay plain strings — `json_extract_path/2` takes strings, so untrusted
  # path keys never touch the atom table.
  defp resolve_json_path(column_atom, name, cast_type) do
    [_column | path] = String.split(name, ".")
    json_expr = dynamic([row], json_extract_path(field(row, ^column_atom), ^path))

    case cast_type do
      nil -> {:ok, json_expr, []}
      type -> {:ok, dynamic([row], type(^json_expr, ^type)), []}
    end
  end

  # --- Operand resolution (literal transform + type coercion) ---

  # Resolves one operand of a comparison/BETWEEN against the opposite side's
  # type. Returns {:ok, {:expr, dynamic}, joins} for a plain expression or
  # {:ok, {:range, lo, hi}, []} when the literal transform declared the
  # string literal to denote an inclusive range.
  defp resolve_operand(ast, target_type, opts) do
    case literal_transform_result(ast, target_type, opts) do
      {:ok, term} ->
        {:ok, {:expr, dynamic([row], ^term)}, []}

      {:range, {lo, hi}} ->
        {:ok, {:range, lo, hi}, []}

      :default ->
        with {:ok, d, joins} <- to_expr_coerced(ast, target_type, opts) do
          {:ok, {:expr, d}, joins}
        end

      {:error, _} = err ->
        err
    end
  end

  # Compiles a comparison whose operands may be ranges. The range table
  # (inclusive bounds):
  #
  #   field == range  →  field >= lo AND field <= hi
  #   field != range  →  NOT (field >= lo AND field <= hi)
  #   field >= range  →  field >= lo        field >  range  →  field > hi
  #   field <= range  →  field <= hi        field <  range  →  field < lo
  #
  # A range on the left flips the operator (`range <= field` ≡ `field >= range`).
  defp compile_comparison(:==, {:expr, l}, {:expr, r}, j), do: {:ok, dynamic([row], ^l == ^r), j}
  defp compile_comparison(:!=, {:expr, l}, {:expr, r}, j), do: {:ok, dynamic([row], ^l != ^r), j}
  defp compile_comparison(:>=, {:expr, l}, {:expr, r}, j), do: {:ok, dynamic([row], ^l >= ^r), j}
  defp compile_comparison(:<=, {:expr, l}, {:expr, r}, j), do: {:ok, dynamic([row], ^l <= ^r), j}
  defp compile_comparison(:>, {:expr, l}, {:expr, r}, j), do: {:ok, dynamic([row], ^l > ^r), j}
  defp compile_comparison(:<, {:expr, l}, {:expr, r}, j), do: {:ok, dynamic([row], ^l < ^r), j}

  defp compile_comparison(:==, {:expr, l}, {:range, lo, hi}, j),
    do: {:ok, dynamic([row], ^l >= ^lo and ^l <= ^hi), j}

  defp compile_comparison(:!=, {:expr, l}, {:range, lo, hi}, j),
    do: {:ok, dynamic([row], not (^l >= ^lo and ^l <= ^hi)), j}

  defp compile_comparison(:>=, {:expr, l}, {:range, lo, _hi}, j),
    do: {:ok, dynamic([row], ^l >= ^lo), j}

  defp compile_comparison(:>, {:expr, l}, {:range, _lo, hi}, j),
    do: {:ok, dynamic([row], ^l > ^hi), j}

  defp compile_comparison(:<=, {:expr, l}, {:range, _lo, hi}, j),
    do: {:ok, dynamic([row], ^l <= ^hi), j}

  defp compile_comparison(:<, {:expr, l}, {:range, lo, _hi}, j),
    do: {:ok, dynamic([row], ^l < ^lo), j}

  defp compile_comparison(op, {:range, _, _} = range, {:expr, _} = expr, j),
    do: compile_comparison(flip_op(op), expr, range, j)

  defp compile_comparison(op, {:range, _, _}, {:range, _, _}, _j) do
    {:error,
     "literal_transform returned a range for both sides of #{op} — " <>
       "at most one side of a comparison may resolve to a range"}
  end

  defp flip_op(:==), do: :==
  defp flip_op(:!=), do: :!=
  defp flip_op(:>=), do: :<=
  defp flip_op(:<=), do: :>=
  defp flip_op(:>), do: :<
  defp flip_op(:<), do: :>

  defp between_bound({:expr, d}, _which), do: d
  defp between_bound({:range, lo, _hi}, :low), do: dynamic([row], ^lo)
  defp between_bound({:range, _lo, hi}, :high), do: dynamic([row], ^hi)

  defp expr_only({:expr, d}, _op_name), do: {:ok, d}

  defp expr_only({:range, _lo, _hi}, op_name) do
    {:error,
     "literal_transform returned a range for #{op_name} — " <>
       "ranges are only supported for comparison and BETWEEN operators"}
  end

  # like/ilike patterns: apply the literal transform (with the pattern
  # field's type) but skip the type coercion — patterns are always text.
  defp resolve_pattern(right, left, op_name, opts) do
    case literal_transform_result(right, field_type(left, opts), opts) do
      {:ok, term} ->
        {:ok, dynamic([row], ^term), []}

      {:range, _} ->
        {:error,
         "literal_transform returned a range for #{op_name} — " <>
           "ranges are only supported for comparison and BETWEEN operators"}

      :default ->
        to_expr(right, opts)

      {:error, _} = err ->
        err
    end
  end

  # IN list elements: run the literal transform per string element against
  # the field's element type. Returns {:ok, transformed?, items} where
  # transformed elements are replaced with {:value, term} nodes; when any
  # element was transformed the list is pinned without a type/2 wrap (the
  # transform owns the types).
  defp transform_list_elements(items, element_type, opts) do
    Enum.reduce_while(items, {:ok, false, []}, fn item, {:ok, transformed?, acc} ->
      case literal_transform_result(item, element_type, opts) do
        {:ok, term} ->
          {:cont, {:ok, true, [{:value, term} | acc]}}

        {:range, _} ->
          {:halt,
           {:error,
            "literal_transform returned a range for an IN list element — " <>
              "ranges are only supported for comparison and BETWEEN operators"}}

        :default ->
          {:cont, {:ok, transformed?, [item | acc]}}

        {:error, _} = err ->
          {:halt, err}
      end
    end)
    |> case do
      {:ok, transformed?, acc} -> {:ok, transformed?, Enum.reverse(acc)}
      {:error, _} = err -> err
    end
  end

  # Invoke the :literal_transform option for a string literal (including a
  # substituted string parameter) resolved against a known target type.
  defp literal_transform_result({:string, raw}, target_type, opts)
       when not is_nil(target_type) do
    case Keyword.get(opts, :literal_transform) do
      fun when is_function(fun, 2) ->
        case fun.(target_type, raw) do
          {:ok, term} ->
            {:ok, term}

          {:range, {_lo, _hi}} = range ->
            range

          :default ->
            :default

          other ->
            {:error,
             "literal_transform must return {:ok, term}, {:range, {lo, hi}}, " <>
               "or :default, got: #{inspect(other)}"}
        end

      _ ->
        :default
    end
  end

  defp literal_transform_result(_ast, _target_type, _opts), do: :default

  # --- Type coercion of literal operands ---

  # When a literal sits opposite a typed field in a comparison, wrap it with
  # `type/2` so Ecto and the DB driver cast it to the column's type rather than
  # sending it as a bare text/integer parameter.
  defp to_expr_coerced(ast, target_type, opts) do
    case coercion_type(ast, target_type) do
      nil ->
        to_expr(ast, opts)

      cast_type ->
        case literal_value(ast) do
          {:ok, value} -> {:ok, dynamic([row], type(^value, ^cast_type)), []}
          :error -> to_expr(ast, opts)
        end
    end
  end

  # Return the type to coerce to, or nil if no coercion should happen.
  # Skip coercion when the literal's natural type already matches the target.
  defp coercion_type(_ast, nil), do: nil
  defp coercion_type({:string, _}, :string), do: nil
  defp coercion_type({:integer, _}, :integer), do: nil
  defp coercion_type({:integer, _}, :id), do: nil
  defp coercion_type({:float, _}, :float), do: nil
  defp coercion_type({:boolean, _}, :boolean), do: nil
  defp coercion_type({:string, _}, type), do: type
  defp coercion_type({:integer, _}, type), do: type
  defp coercion_type({:float, _}, type), do: type
  defp coercion_type({:boolean, _}, type), do: type
  # Bound parameter values without a literal syntax (Date, Decimal, ...) are
  # always wrapped when a target type is known; `type/2` casting a value that
  # already matches the column type is a no-op.
  defp coercion_type({:value, _}, type), do: type

  defp coercion_type({:list, items}, {:array, inner}) when not is_nil(inner) do
    if Enum.all?(items, &(coercion_type(&1, inner) == nil)) do
      nil
    else
      {:array, inner}
    end
  end

  defp coercion_type(_, _), do: nil

  defp literal_value({:string, v}), do: {:ok, v}
  defp literal_value({:integer, v}), do: {:ok, v}
  defp literal_value({:float, v}), do: {:ok, v}
  defp literal_value({:boolean, v}), do: {:ok, v}
  defp literal_value({:value, v}), do: {:ok, v}

  defp literal_value({:list, items}) do
    case literal_values(items) do
      {:ok, values} -> {:ok, values}
      {:error, _} -> :error
    end
  end

  defp literal_value(_), do: :error

  # Extract raw values from a list of literal AST nodes.
  defp literal_values(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case literal_value(item) do
        {:ok, v} ->
          {:cont, {:ok, [v | acc]}}

        :error ->
          {:halt, {:error, "lists may only contain literal values, got: #{inspect(item)}"}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _} = err -> err
    end
  end

  # --- Field type resolution ---

  # Returns the Ecto type of the field referenced by an identifier AST node,
  # or nil if the AST is not an identifier, the field is unknown, or no type
  # information is available.
  defp field_type({:identifier, name}, opts) do
    if String.contains?(name, ".") do
      dotted_field_type(name, opts)
    else
      simple_field_type(name, opts)
    end
  end

  defp field_type(_, _), do: nil

  defp simple_field_type(name, opts) do
    case existing_atom(name) do
      {:ok, atom} ->
        case get_field_type(atom, opts) do
          nil -> schema_field_type(atom, opts)
          type -> type
        end

      :error ->
        nil
    end
  end

  defp schema_field_type(atom, opts) do
    case Keyword.fetch(opts, :schema) do
      {:ok, schema} -> schema.__schema__(:type, atom)
      :error -> nil
    end
  end

  defp dotted_field_type(name, opts) do
    first_segment_str = name |> String.split(".", parts: 2) |> hd()

    case existing_atom(first_segment_str) do
      {:ok, first_segment} ->
        case Keyword.fetch(opts, :schema) do
          {:ok, schema} ->
            if is_json_field?(schema, first_segment) do
              json_path_field_type(name, opts)
            else
              schema_assoc_field_type(name, schema)
            end

          :error ->
            value = get_field_type(first_segment, opts)

            cond do
              value == :map -> json_path_field_type(name, opts)
              singular_assoc?(value) -> allowed_assoc_field_type(name, opts)
              true -> nil
            end
        end

      :error ->
        nil
    end
  end

  defp json_path_field_type(name, opts) do
    case existing_atom(name) do
      {:ok, atom} -> get_field_type(atom, opts)
      :error -> nil
    end
  end

  defp schema_assoc_field_type(name, schema) do
    segments = String.split(name, ".")
    assoc_segments = Enum.slice(segments, 0..-2//1)
    field_str = List.last(segments)

    with {:ok, field_atom} <- existing_atom(field_str),
         {:ok, leaf_schema} <- walk_schema_assocs(assoc_segments, schema) do
      leaf_schema.__schema__(:type, field_atom)
    else
      _ -> nil
    end
  end

  defp walk_schema_assocs([], schema), do: {:ok, schema}

  defp walk_schema_assocs([segment | rest], schema) do
    with {:ok, assoc_atom} <- existing_atom(segment),
         assoc when not is_nil(assoc) <- schema.__schema__(:association, assoc_atom) do
      walk_schema_assocs(rest, assoc.queryable)
    else
      _ -> :error
    end
  end

  defp allowed_assoc_field_type(name, opts) do
    allowed = Keyword.get(opts, :allowed_fields, [])
    walk_allowed_assocs(String.split(name, "."), allowed)
  end

  defp walk_allowed_assocs([last], fields) do
    case existing_atom(last) do
      {:ok, atom} -> Keyword.get(fields, atom)
      :error -> nil
    end
  end

  defp walk_allowed_assocs([head | rest], fields) do
    with {:ok, atom} <- existing_atom(head),
         value when not is_nil(value) <- Keyword.get(fields, atom),
         true <- singular_assoc?(value) do
      sub_fields = Keyword.get(assoc_opts(value), :fields, [])
      walk_allowed_assocs(rest, sub_fields)
    else
      _ -> nil
    end
  end

  defp existing_atom(name) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> :error
  end

  # --- Association tuple helpers ---

  # `{:assoc, ...}` is preserved as a backward-compatible alias for
  # `{:belongs_to, ...}`. Plural assocs (`:has_many`, `:many_to_many`) are
  # detected here for completeness but are never traversed as singular —
  # they are rewritten out of the AST by EctoQueryParser.ExistsRewriter
  # before the Builder sees them.
  defp assoc_kind({:assoc, _}), do: :belongs_to
  defp assoc_kind({:belongs_to, _}), do: :belongs_to
  defp assoc_kind({:has_many, _}), do: :has_many
  defp assoc_kind({:many_to_many, _}), do: :many_to_many
  defp assoc_kind(_), do: nil

  defp assoc_opts({_kind, opts}) when is_list(opts), do: opts

  defp singular_assoc?(value), do: assoc_kind(value) == :belongs_to

  # --- EXISTS subquery construction ---

  defp build_exists_subquery(:has_many, aopts, inner_dynamic, inner_joins, source_binding) do
    base = source_query(aopts.table, aopts.prefix)
    owner_key = aopts.owner_key
    related_key = aopts.related_key

    base
    |> where(
      [t],
      field(t, ^related_key) == field(parent_as(^source_binding), ^owner_key)
    )
    |> EctoQueryParser.Joins.apply(inner_joins)
    |> where(^inner_dynamic)
    |> select([_], 1)
  end

  defp build_exists_subquery(:many_to_many, aopts, inner_dynamic, inner_joins, source_binding) do
    target_base = source_query(aopts.table, aopts.prefix)
    join_table = aopts.join_through
    join_prefix = aopts.join_prefix
    owner_key = aopts.owner_key
    related_key = aopts.related_key
    join_owner_key = aopts.join_owner_key
    join_related_key = aopts.join_related_key

    target_base
    |> add_inner_join(join_table, join_prefix, join_related_key, related_key)
    |> where(
      [t, jt],
      field(jt, ^join_owner_key) == field(parent_as(^source_binding), ^owner_key)
    )
    |> EctoQueryParser.Joins.apply(inner_joins)
    |> where(^inner_dynamic)
    |> select([_], 1)
  end

  # The join target must be a bare string so Ecto can build a plain
  # `INNER JOIN "schema"."table"`; passing `^{prefix, table}` would fall
  # through to `Ecto.Queryable.to_query/1` which rejects {string, string}
  # tuples, and passing `^%Ecto.Query{}` would wrap as a subquery join.
  # Use join/5's `:prefix` keyword option for the schema prefix instead.
  defp add_inner_join(query, table, nil, join_related_key, related_key) do
    join(query, :inner, [t], jt in ^table,
      on: field(jt, ^join_related_key) == field(t, ^related_key)
    )
  end

  defp add_inner_join(query, table, prefix, join_related_key, related_key)
       when is_binary(prefix) do
    join(query, :inner, [t], jt in ^table,
      on: field(jt, ^join_related_key) == field(t, ^related_key),
      prefix: ^prefix
    )
  end

  # Build a base %Ecto.Query{} from a string table name, applying the prefix
  # to the FromExpr so the subquery sources from the right schema namespace.
  defp source_query(table, nil), do: Ecto.Queryable.to_query(table)

  defp source_query(table, prefix) when is_binary(prefix) do
    query = Ecto.Queryable.to_query(table)
    %{query | from: %{query.from | prefix: prefix}}
  end
end
