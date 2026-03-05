defmodule EctoQueryParser.Parser do
  @moduledoc """
  NimbleParsec-based parser for the Ecto query language.

  Parses data types into an AST representation:

  - Strings: `"foo"` → `{:string, "foo"}`
  - Integers: `42` → `{:integer, 42}`
  - Floats: `3.14` → `{:float, 3.14}`
  - Booleans: `true`/`TRUE` → `{:boolean, true}`
  - Identifiers: `column_1` → `{:identifier, "column_1"}`
  - Lists: `[1, 2]` → `{:list, [{:integer, 1}, {:integer, 2}]}`
  - Functions: `TO_UPPER(col)` → `{:function, "to_upper", [{:identifier, "col"}]}`
  - Operators: `col == 1` → `{:op, :==, {:identifier, "col"}, {:integer, 1}}`
  - AND/OR: `a == 1 AND b == 2` → `{:and, [op1, op2]}`
  - Grouping: `(a == 1 OR b == 2) AND c == 3` → `{:and, [{:or, [...]}, ...]}`
  """

  import NimbleParsec

  # Whitespace
  whitespace = ascii_string([?\s, ?\t, ?\n, ?\r], min: 0)
  _required_whitespace = ascii_string([?\s, ?\t, ?\n, ?\r], min: 1)

  # String literal: double-quoted, supports escape sequences
  escaped_char =
    ignore(string("\\"))
    |> ascii_char([?\\, ?", ?n, ?t, ?r])
    |> map({__MODULE__, :unescape_char, []})

  string_char =
    choice([
      escaped_char,
      utf8_char([{:not, ?"}, {:not, ?\\}])
    ])

  string_literal =
    ignore(string("\""))
    |> repeat(string_char)
    |> ignore(string("\""))
    |> reduce({__MODULE__, :chars_to_string, []})
    |> unwrap_and_tag(:string)

  # Integer and float literals
  sign = ascii_char([?-, ?+]) |> map({__MODULE__, :sign_char, []})
  digits = ascii_string([?0..?9], min: 1)

  float_literal =
    optional(sign)
    |> concat(digits)
    |> concat(string("."))
    |> concat(digits)
    |> reduce({__MODULE__, :to_float, []})
    |> unwrap_and_tag(:float)

  integer_literal =
    optional(sign)
    |> concat(digits)
    |> reduce({__MODULE__, :to_integer, []})
    |> unwrap_and_tag(:integer)

  # Boolean literal (case-insensitive)
  boolean_true =
    choice([string("true"), string("TRUE"), string("True")])
    |> replace(true)
    |> unwrap_and_tag(:boolean)

  boolean_false =
    choice([string("false"), string("FALSE"), string("False")])
    |> replace(false)
    |> unwrap_and_tag(:boolean)

  boolean_literal = choice([boolean_true, boolean_false])

  # Identifier: starts with a letter or underscore, followed by letters, digits, underscores, or dots
  identifier =
    ascii_char([?a..?z, ?A..?Z, ?_])
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_, ?.]))
    |> reduce({__MODULE__, :chars_to_string, []})
    |> unwrap_and_tag(:identifier)

  # Function name: letters, digits, underscores (must start with letter or underscore)
  function_name =
    ascii_char([?a..?z, ?A..?Z, ?_])
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_]))
    |> reduce({__MODULE__, :chars_to_string, []})

  # Value (non-recursive, used inside lists and functions)
  # We use parsec/1 to handle the recursive nature of lists and functions
  value =
    ignore(whitespace)
    |> choice([
      string_literal,
      boolean_literal,
      parsec(:list_value),
      float_literal,
      integer_literal,
      parsec(:function_call),
      identifier
    ])
    |> ignore(whitespace)

  # Comma-separated values
  comma = ignore(whitespace) |> ignore(string(",")) |> ignore(whitespace)

  values_list =
    value
    |> repeat(comma |> concat(value))

  # List literal: [value, value, ...]
  list_literal =
    ignore(string("["))
    |> ignore(whitespace)
    |> optional(values_list)
    |> ignore(whitespace)
    |> ignore(string("]"))
    |> tag(:list)

  # Function call: name(arg1, arg2, ...)
  function_call =
    function_name
    |> ignore(whitespace)
    |> ignore(string("("))
    |> ignore(whitespace)
    |> optional(values_list)
    |> ignore(whitespace)
    |> ignore(string(")"))
    |> reduce({__MODULE__, :to_function, []})

  # Single operand (a standalone value)
  operand =
    ignore(whitespace)
    |> choice([
      string_literal,
      boolean_literal,
      list_literal,
      float_literal,
      integer_literal,
      function_call,
      identifier
    ])
    |> ignore(whitespace)

  # Symbolic operators
  symbolic_operator =
    choice([
      string("==") |> replace(:==),
      string("!=") |> replace(:!=),
      string(">=") |> replace(:>=),
      string("<=") |> replace(:<=)
    ])

  # Keyword operator: must not be followed by identifier characters
  # This prevents "includes_flag" from being parsed as operator "includes" + "_flag"
  not_ident_char = lookahead_not(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_]))

  keyword_operator =
    choice([
      choice([string("includes"), string("INCLUDES")]) |> replace(:includes),
      choice([string("contains"), string("CONTAINS")]) |> replace(:contains),
      choice([string("ilike"), string("ILIKE")]) |> replace(:ilike),
      choice([string("like"), string("LIKE")]) |> replace(:like),
      choice([string("search"), string("SEARCH")]) |> replace(:search)
    ])
    |> concat(not_ident_char)

  # Operator expression: operand operator operand
  # Note: operand already consumes surrounding whitespace, so no extra
  # whitespace handling is needed here. The keyword_operator's not_ident_char
  # lookahead prevents matching partial identifiers like "includes_flag".
  operator_expression =
    operand
    |> choice([
      symbolic_operator,
      keyword_operator
    ])
    |> concat(operand)
    |> reduce({__MODULE__, :to_operator, []})

  # Logical connectors (case-insensitive, must not be followed by identifier chars)
  and_connector =
    ignore(choice([string("AND"), string("and")]))
    |> concat(not_ident_char)

  or_connector =
    ignore(choice([string("OR"), string("or")]))
    |> concat(not_ident_char)

  # Grouped expression: ( or_expression )
  grouped =
    ignore(string("("))
    |> ignore(whitespace)
    |> parsec(:or_expr)
    |> ignore(whitespace)
    |> ignore(string(")"))

  # Primary: grouped expression, comparison, or standalone value
  primary =
    ignore(whitespace)
    |> choice([
      grouped,
      operator_expression,
      operand
    ])
    |> ignore(whitespace)

  # AND chains: primary AND primary AND ...
  # AND binds tighter than OR
  and_expression =
    parsec(:primary_expr)
    |> repeat(
      and_connector
      |> parsec(:primary_expr)
    )
    |> reduce({__MODULE__, :build_and, []})

  # OR chains: and_expr OR and_expr OR ...
  or_expression =
    parsec(:and_expr)
    |> repeat(
      or_connector
      |> parsec(:and_expr)
    )
    |> reduce({__MODULE__, :build_or, []})

  defcombinatorp(:function_call, function_call)
  defcombinatorp(:list_value, list_literal)
  defcombinatorp(:primary_expr, primary)
  defcombinatorp(:and_expr, and_expression)
  defcombinatorp(:or_expr, or_expression)
  defparsec(:parse_raw, or_expression |> eos())

  @doc """
  Parses an input string into an AST node.

  Returns `{:ok, ast_node}` on success or `{:error, reason}` on failure.
  """
  def parse(input) when is_binary(input) do
    case parse_raw(input) do
      {:ok, [result], "", _, _, _} ->
        {:ok, result}

      {:ok, _, rest, _, _, _} ->
        {:error, "unexpected input: #{inspect(rest)}"}

      {:error, reason, _rest, _context, _position, _byte_offset} ->
        {:error, reason}
    end
  end

  @doc false
  def unescape_char(?n), do: ?\n
  def unescape_char(?t), do: ?\t
  def unescape_char(?r), do: ?\r
  def unescape_char(?\\), do: ?\\
  def unescape_char(?"), do: ?"

  @doc false
  def chars_to_string(chars), do: List.to_string(chars)

  @doc false
  def sign_char(?-), do: "-"
  def sign_char(?+), do: ""

  @doc false
  def to_integer(parts) do
    parts |> Enum.join() |> String.to_integer()
  end

  @doc false
  def to_float(parts) do
    parts |> Enum.join() |> String.to_float()
  end

  @doc false
  def to_function([name | args]) do
    {:function, String.downcase(name), args}
  end

  @doc false
  def to_operator([left, op, right]) do
    {:op, op, left, right}
  end

  @doc false
  def build_and([single]), do: single
  def build_and(items), do: {:and, items}

  @doc false
  def build_or([single]), do: single
  def build_or(items), do: {:or, items}
end
