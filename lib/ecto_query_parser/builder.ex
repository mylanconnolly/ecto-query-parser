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
    with {:ok, l, lj} <- to_expr(left, opts),
         {:ok, r, rj} <- to_expr(right, opts) do
      {:ok, dynamic([row], ^l == ^r), lj ++ rj}
    end
  end

  defp to_dynamic({:op, :!=, left, right}, opts) do
    with {:ok, l, lj} <- to_expr(left, opts),
         {:ok, r, rj} <- to_expr(right, opts) do
      {:ok, dynamic([row], ^l != ^r), lj ++ rj}
    end
  end

  defp to_dynamic({:op, :>=, left, right}, opts) do
    with {:ok, l, lj} <- to_expr(left, opts),
         {:ok, r, rj} <- to_expr(right, opts) do
      {:ok, dynamic([row], ^l >= ^r), lj ++ rj}
    end
  end

  defp to_dynamic({:op, :<=, left, right}, opts) do
    with {:ok, l, lj} <- to_expr(left, opts),
         {:ok, r, rj} <- to_expr(right, opts) do
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
    with {:ok, l, lj} <- to_expr(left, opts),
         {:ok, r, rj} <- to_expr(right, opts) do
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
    do:
      {:ok, dynamic([row], fragment("CONCAT(?, ?, ?, ?, ?, ?, ?)", ^a, ^b, ^c, ^d, ^e, ^f, ^g))}

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

        case Keyword.get(fields, first_atom) do
          {:assoc, assoc_opts} ->
            nested_fields = Keyword.get(assoc_opts, :fields, [])
            rest_atom = String.to_atom(rest)

            if nested_fields == [] or Keyword.has_key?(nested_fields, rest_atom) do
              :ok
            else
              check_nested_field(rest_atom, nested_fields)
            end

          _ ->
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
    case get_field_type(first_segment, opts) do
      :map ->
        cast_type = get_field_type(dotted_atom, opts)
        resolve_json_path(name, cast_type, opts)

      {:assoc, _} ->
        resolve_schemaless_join(name, opts)

      nil ->
        {:error,
         "cannot resolve dotted identifier #{name}: " <>
           "no schema available and #{first_segment} is not defined in allowed_fields"}

      _ ->
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

    case Keyword.get(fields, assoc_atom) do
      {:assoc, assoc_opts} ->
        new_path = path ++ [segment]
        binding = new_path |> Enum.join("__") |> String.to_atom()

        join_spec = %{
          binding: binding,
          table: Keyword.fetch!(assoc_opts, :table),
          owner_key: Keyword.fetch!(assoc_opts, :owner_key),
          related_key: Keyword.fetch!(assoc_opts, :related_key),
          parent: parent
        }

        sub_fields = Keyword.get(assoc_opts, :fields, [])
        walk_schemaless_assocs(rest, sub_fields, binding, new_path, [join_spec | joins])

      nil ->
        {:error, "unknown association: #{segment}"}

      _ ->
        {:error, "#{segment} is not an association"}
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
end
