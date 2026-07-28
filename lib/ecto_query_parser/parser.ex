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
  - NOT: `NOT a == 1` → `{:not, {:op, :==, ...}}`
  - IS NULL: `col IS NULL` → `{:is_null, {:identifier, "col"}}`
  - IS NOT NULL: `col IS NOT NULL` → `{:is_not_null, {:identifier, "col"}}`
  - BETWEEN: `col BETWEEN 1 AND 10` → `{:between, {:identifier, "col"}, {:integer, 1}, {:integer, 10}}`
  - Grouping: `(a == 1 OR b == 2) AND c == 3` → `{:and, [{:or, [...]}, ...]}`

  Parse failures return `{:error, %EctoQueryParser.ParseError{}}` with line,
  column, and byte-offset information.
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

  # Symbolic operators. Order matters: ">=" / "<=" must be tried before the
  # strict ">" / "<" so "age >= 18" never parses as `age > (= 18)`.
  symbolic_operator =
    choice([
      string("==") |> replace(:==),
      string("!=") |> replace(:!=),
      string(">=") |> replace(:>=),
      string("<=") |> replace(:<=),
      string(">") |> replace(:>),
      string("<") |> replace(:<)
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
      choice([string("search"), string("SEARCH")]) |> replace(:search),
      choice([string("in"), string("IN")]) |> replace(:in)
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

  # NOT / IS / NULL / BETWEEN keywords, same casing convention as AND/OR
  # (all-uppercase or all-lowercase, never followed by identifier chars)
  not_keyword =
    ignore(choice([string("NOT"), string("not")]))
    |> concat(not_ident_char)

  is_keyword =
    ignore(choice([string("IS"), string("is")]))
    |> concat(not_ident_char)

  between_keyword =
    ignore(choice([string("BETWEEN"), string("between")]))
    |> concat(not_ident_char)

  # IS NULL / IS NOT NULL: postfix on an operand (identifier or function call)
  is_null_expression =
    operand
    |> ignore(is_keyword)
    |> ignore(whitespace)
    |> choice([
      choice([string("NOT"), string("not")])
      |> concat(not_ident_char)
      |> ignore(whitespace)
      |> concat(choice([string("NULL"), string("null")]))
      |> concat(not_ident_char)
      |> replace(:is_not_null),
      choice([string("NULL"), string("null")])
      |> concat(not_ident_char)
      |> replace(:is_null)
    ])
    |> reduce({__MODULE__, :to_null_check, []})

  # BETWEEN: `expr BETWEEN low AND high` parsed as one unit so the inner AND
  # binds to BETWEEN rather than acting as a logical connector.
  between_expression =
    operand
    |> ignore(between_keyword)
    |> concat(operand)
    |> ignore(and_connector)
    |> concat(operand)
    |> reduce({__MODULE__, :to_between, []})

  # NOT: unary logical negation of a primary expression.
  # Precedence: NOT > AND > OR.
  negation =
    not_keyword
    |> parsec(:primary_expr)
    |> reduce({__MODULE__, :build_not, []})

  # Grouped expression: ( or_expression )
  grouped =
    ignore(string("("))
    |> ignore(whitespace)
    |> parsec(:or_expr)
    |> ignore(whitespace)
    |> ignore(string(")"))

  # Primary: negation, grouped expression, comparison, or standalone value.
  # Multi-token forms (BETWEEN, IS NULL, operator expressions) must be tried
  # before the bare operand, since choice/1 commits to the first branch that
  # succeeds.
  primary =
    ignore(whitespace)
    |> choice([
      negation,
      grouped,
      between_expression,
      is_null_expression,
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

  # The label keeps failure messages to a single readable line instead of
  # NimbleParsec's exhaustive multi-kilobyte choice dump; the ParseError's
  # line/column/rest carry the precise diagnostics.
  defparsec(:parse_raw, label(or_expression, "a filter expression") |> eos())

  @max_rest_length 60

  @doc """
  Parses an input string into an AST node.

  Returns `{:ok, ast_node}` on success or
  `{:error, %EctoQueryParser.ParseError{}}` on failure. The error struct
  carries the 1-based `line` and `column`, the `byte_offset`, and the
  (truncated) unconsumed `rest` of the input.
  """
  def parse(input) when is_binary(input) do
    case parse_raw(input) do
      {:ok, [result], "", _, _, _} ->
        {:ok, result}

      {:ok, _, rest, _, position, byte_offset} ->
        {:error, parse_error("unexpected input: #{inspect(rest)}", rest, position, byte_offset)}

      {:error, reason, rest, _context, position, byte_offset} ->
        {:error, parse_error(reason, rest, position, byte_offset)}
    end
  end

  # NimbleParsec reports position as {line, byte offset at which the line
  # starts}; the column is derived from the distance into that line.
  defp parse_error(reason, rest, {line, line_start_offset}, byte_offset) do
    %EctoQueryParser.ParseError{
      message: reason,
      line: line,
      column: byte_offset - line_start_offset + 1,
      byte_offset: byte_offset,
      rest: truncate(rest)
    }
  end

  defp truncate(rest) when byte_size(rest) <= @max_rest_length, do: rest

  defp truncate(rest) do
    String.slice(rest, 0, @max_rest_length) <> "..."
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
  def to_null_check([operand, :is_null]), do: {:is_null, operand}
  def to_null_check([operand, :is_not_null]), do: {:is_not_null, operand}

  @doc false
  def to_between([target, low, high]), do: {:between, target, low, high}

  @doc false
  def build_not([expr]), do: {:not, expr}

  @doc false
  def build_and([single]), do: single
  def build_and(items), do: {:and, items}

  @doc false
  def build_or([single]), do: single
  def build_or(items), do: {:or, items}
end
