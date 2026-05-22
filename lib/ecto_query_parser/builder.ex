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

  Returns `{:ok, dynamic, joins}` or `{:error, reason}`.
  """
  def build(ast, opts \\ []) do
    to_dynamic(ast, opts)
  end

  # EXISTS: emitted by EctoQueryParser.ExistsRewriter for has_many /
  # many_to_many references. The inner AST is built against the nested
  # context (`sub_opts`), then wrapped in a correlated subquery.
  defp to_dynamic({:exists, _binding, kind, aopts, inner_ast, sub_opts}, opts) do
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

  # Comparison operators
  defp to_dynamic({:op, :==, left, right}, opts) do
    with {:ok, l, lj, r, rj} <- build_comparison_operands(left, right, opts) do
      {:ok, dynamic([row], ^l == ^r), lj ++ rj}
    end
  end

  defp to_dynamic({:op, :!=, left, right}, opts) do
    with {:ok, l, lj, r, rj} <- build_comparison_operands(left, right, opts) do
      {:ok, dynamic([row], ^l != ^r), lj ++ rj}
    end
  end

  defp to_dynamic({:op, :>=, left, right}, opts) do
    with {:ok, l, lj, r, rj} <- build_comparison_operands(left, right, opts) do
      {:ok, dynamic([row], ^l >= ^r), lj ++ rj}
    end
  end

  defp to_dynamic({:op, :<=, left, right}, opts) do
    with {:ok, l, lj, r, rj} <- build_comparison_operands(left, right, opts) do
      {:ok, dynamic([row], ^l <= ^r), lj ++ rj}
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

  # like / ilike: pass pattern through directly
  defp to_dynamic({:op, :like, left, right}, opts) do
    with {:ok, l, lj} <- to_expr(left, opts),
         {:ok, r, rj} <- to_expr(right, opts) do
      {:ok, dynamic([row], like(^l, ^r)), lj ++ rj}
    end
  end

  defp to_dynamic({:op, :ilike, left, right}, opts) do
    with {:ok, l, lj} <- to_expr(left, opts),
         {:ok, r, rj} <- to_expr(right, opts) do
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
         {:ok, r, rj} <- to_expr_coerced(right, element_type, opts) do
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
    values =
      Enum.map(items, fn
        {:string, v} -> v
        {:integer, v} -> v
        {:float, v} -> v
        {:boolean, v} -> v
      end)

    {:ok, dynamic([row], ^values), []}
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

  defp resolve_dotted_identifier(name, opts) do
    dotted_atom = String.to_atom(name)

    with :ok <- check_allowed_field(dotted_atom, opts) do
      first_segment = name |> String.split(".", parts: 2) |> hd() |> String.to_atom()

      case Keyword.fetch(opts, :schema) do
        {:ok, schema} ->
          if is_json_field?(schema, first_segment) do
            cast_type = get_field_type(dotted_atom, opts)
            resolve_json_path(name, cast_type, opts)
          else
            EctoQueryParser.JoinResolver.resolve(name, schema)
          end

        :error ->
          resolve_dotted_from_allowed_fields(name, first_segment, dotted_atom, opts)
      end
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

  defp check_allowed_field(atom, opts) do
    case Keyword.fetch(opts, :allowed_fields) do
      {:ok, allowed} when is_list(allowed) ->
        if Keyword.keyword?(allowed) do
          cond do
            Keyword.has_key?(allowed, atom) -> :ok
            check_nested_field(atom, allowed) == :ok -> :ok
            true -> {:error, "field not allowed: #{atom}"}
          end
        else
          if atom in allowed, do: :ok, else: {:error, "field not allowed: #{atom}"}
        end

      :error ->
        :ok
    end
  end

  defp check_nested_field(atom, fields) do
    name = Atom.to_string(atom)

    case String.split(name, ".", parts: 2) do
      [first, rest] ->
        first_atom = String.to_atom(first)
        value = Keyword.get(fields, first_atom)

        if singular_assoc?(value) do
          nested_fields = Keyword.get(assoc_opts(value), :fields, [])
          rest_atom = String.to_atom(rest)

          if nested_fields == [] or Keyword.has_key?(nested_fields, rest_atom) do
            :ok
          else
            check_nested_field(rest_atom, nested_fields)
          end
        else
          {:error, "field not allowed: #{name}"}
        end

      _ ->
        {:error, "field not allowed: #{name}"}
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

  defp resolve_dotted_from_allowed_fields(name, first_segment, dotted_atom, opts) do
    value = get_field_type(first_segment, opts)

    cond do
      value == :map ->
        cast_type = get_field_type(dotted_atom, opts)
        resolve_json_path(name, cast_type, opts)

      singular_assoc?(value) ->
        resolve_schemaless_join(name, opts)

      value == nil ->
        {:error,
         "cannot resolve dotted identifier #{name}: " <>
           "no schema available and #{first_segment} is not defined in allowed_fields"}

      true ->
        {:error,
         "cannot resolve dotted identifier #{name}: " <>
           "#{first_segment} is not an association or map field"}
    end
  end

  defp resolve_schemaless_join(name, opts) do
    segments = String.split(name, ".")
    assoc_segments = Enum.slice(segments, 0..-2//1)
    field_name = List.last(segments) |> String.to_atom()
    allowed_fields = Keyword.get(opts, :allowed_fields, [])

    case walk_schemaless_assocs(assoc_segments, allowed_fields, :root, [], []) do
      {:ok, joins, final_binding} ->
        expr = dynamic([{^final_binding, x}], field(x, ^field_name))
        {:ok, expr, joins}

      {:error, _} = error ->
        error
    end
  end

  defp walk_schemaless_assocs([], _fields, binding, _path, joins),
    do: {:ok, Enum.reverse(joins), binding}

  defp walk_schemaless_assocs([segment | rest], fields, parent, path, joins) do
    assoc_atom = String.to_atom(segment)
    value = Keyword.get(fields, assoc_atom)

    cond do
      singular_assoc?(value) ->
        assoc_opts = assoc_opts(value)
        new_path = path ++ [segment]
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

  defp resolve_json_path(name, cast_type, _opts) do
    [column | path] = String.split(name, ".")
    column_atom = String.to_atom(column)
    json_expr = dynamic([row], json_extract_path(field(row, ^column_atom), ^path))

    case cast_type do
      nil -> {:ok, json_expr, []}
      type -> {:ok, dynamic([row], type(^json_expr, ^type)), []}
    end
  end

  # --- Type coercion of literal operands ---

  # Resolves both operands of a comparison, applying type coercion when one
  # side is a literal and the other identifies a typed field.
  defp build_comparison_operands(left, right, opts) do
    left_type = field_type(left, opts)
    right_type = field_type(right, opts)

    with {:ok, l, lj} <- to_expr_coerced(left, right_type, opts),
         {:ok, r, rj} <- to_expr_coerced(right, left_type, opts) do
      {:ok, l, lj, r, rj}
    end
  end

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

  defp coercion_type({:list, _}, {:array, inner})
       when not is_nil(inner) and inner != :string,
       do: {:array, inner}

  defp coercion_type(_, _), do: nil

  defp literal_value({:string, v}), do: {:ok, v}
  defp literal_value({:integer, v}), do: {:ok, v}
  defp literal_value({:float, v}), do: {:ok, v}
  defp literal_value({:boolean, v}), do: {:ok, v}

  defp literal_value({:list, items}) do
    values =
      Enum.map(items, fn
        {:string, v} -> v
        {:integer, v} -> v
        {:float, v} -> v
        {:boolean, v} -> v
      end)

    {:ok, values}
  end

  defp literal_value(_), do: :error

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
