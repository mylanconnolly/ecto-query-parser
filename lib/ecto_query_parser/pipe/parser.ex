defmodule EctoQueryParser.Pipe.Parser do
  @moduledoc """
  NimbleParsec-based parser for the staged pipe language.

  A pipe query is a source followed by zero or more `|`-separated stages:

      orders
      | filter status == "paid"
      | group customer.region { total = sum(amount), n = count() }
      | sort -total
      | limit 10

  Whitespace (including newlines) is insignificant around `|`. The `filter`
  stage embeds the existing filter grammar (`EctoQueryParser.Parser`)
  verbatim, so everything valid in a plain filter string — parameters and
  optional groups included — is valid inside `| filter`.

  Identifiers, aliases, and stage keywords in the pipe grammar are annotated
  with their source position (`%{line: l, column: c, offset: o}`), so
  stage-level validation errors can point at the offending token. Stage AST
  nodes:

  - `{:filter, filter_ast, pos}` — `filter_ast` is the untouched filter AST.
  - `{:select, items, pos}` — items are `{:pcol, name, pos}` or
    `{:aliased, alias, pos, {:pfunc, fname, pos, args}}`.
  - `{:group, breakouts, aggs, pos}` — breakouts share the select item
    shapes plus bare `{:pfunc, ...}`; aggs are
    `{:agg, alias, pos, fun, arg_or_nil}` with `fun` one of
    `count`, `count_distinct`, `sum`, `avg`, `min`, `max`.
  - `{:sort, keys, pos}` — keys are `{:key, :asc | :desc, name, pos}`.
  - `{:limit, n, pos}` / `{:offset, n, pos}` — non-negative integers only.

  Parse failures return `{:error, %EctoQueryParser.ParseError{}}` with the
  usual line/column/byte-offset diagnostics.
  """

  import NimbleParsec

  alias EctoQueryParser.ParseError

  @agg_functions ~w(count count_distinct sum avg min max)

  ws = ascii_string([?\s, ?\t, ?\n, ?\r], min: 0)

  ident_start = [?a..?z, ?A..?Z, ?_]
  ident_char = [?a..?z, ?A..?Z, ?0..?9, ?_]

  # Bare identifier segment: no dots. Used for aliases and function names.
  bare_name =
    ascii_char(ident_start)
    |> repeat(ascii_char(ident_char))
    |> reduce({List, :to_string, []})

  # Table-name segment. Unlike an alias, this names something that already
  # exists in the database, and real schema and table names carry characters an
  # unquoted SQL identifier can't — a schema-per-tenant layout naming schemas
  # after UUIDs (`client_559de6a3-0cc8-4813-…`) is the motivating case. Hyphens
  # are unambiguous here because a table reference only ever appears in the
  # source position, where there is no arithmetic for a `-` to belong to and
  # nothing else may begin. The segment still has to *start* like an
  # identifier, so a source can never be mistaken for a negative number.
  table_segment =
    ascii_char(ident_start)
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_, ?-]))
    |> reduce({List, :to_string, []})

  # Positioned alias / function name.
  pname = bare_name |> post_traverse({:tag_pos, [:pname]})

  # Positioned column reference (dotted paths allowed — association paths and
  # JSONB paths resolve exactly as in the filter grammar).
  pcol =
    ascii_char(ident_start)
    |> repeat(ascii_char([?a..?z, ?A..?Z, ?0..?9, ?_, ?.]))
    |> reduce({List, :to_string, []})
    |> post_traverse({:tag_pos, [:pcol]})

  # Stage keyword with an identifier boundary; emits the keyword's position.
  keyword = fn text ->
    string(text)
    |> lookahead_not(ascii_char(ident_char))
    |> post_traverse({:kw_pos, []})
  end

  # `=` for aliases, distinguished from the filter grammar's `==`.
  alias_eq = string("=") |> lookahead_not(string("="))

  # --- Literals (function arguments) ---
  #
  # A small copy of the filter grammar's literal combinators; the shared
  # helper functions live on EctoQueryParser.Parser.

  escaped_char =
    ignore(string("\\"))
    |> ascii_char([?\\, ?", ?n, ?t, ?r])
    |> map({EctoQueryParser.Parser, :unescape_char, []})

  string_char =
    choice([
      escaped_char,
      utf8_char([{:not, ?"}, {:not, ?\\}])
    ])

  string_literal =
    ignore(string("\""))
    |> repeat(string_char)
    |> ignore(string("\""))
    |> reduce({EctoQueryParser.Parser, :chars_to_string, []})
    |> unwrap_and_tag(:string)

  sign = ascii_char([?-, ?+]) |> map({EctoQueryParser.Parser, :sign_char, []})
  digits = ascii_string([?0..?9], min: 1)

  float_literal =
    optional(sign)
    |> concat(digits)
    |> concat(string("."))
    |> concat(digits)
    |> reduce({EctoQueryParser.Parser, :to_float, []})
    |> unwrap_and_tag(:float)

  integer_literal =
    optional(sign)
    |> concat(digits)
    |> reduce({EctoQueryParser.Parser, :to_integer, []})
    |> unwrap_and_tag(:integer)

  boolean_literal =
    choice([
      choice([string("true"), string("TRUE"), string("True")]) |> replace(true),
      choice([string("false"), string("FALSE"), string("False")]) |> replace(false)
    ])
    |> lookahead_not(ascii_char(ident_char))
    |> unwrap_and_tag(:boolean)

  # --- Function application (select aliases, group breakouts) ---

  farg =
    ignore(ws)
    |> choice([
      string_literal,
      boolean_literal,
      float_literal,
      integer_literal,
      parsec(:pfunc),
      pcol
    ])
    |> ignore(ws)

  pfunc =
    pname
    |> ignore(ws)
    |> ignore(string("("))
    |> ignore(ws)
    |> optional(farg |> repeat(ignore(string(",")) |> concat(farg)))
    |> ignore(ws)
    |> ignore(string(")"))
    |> reduce({:to_pfunc, []})

  defcombinatorp(:pfunc, pfunc)

  aliased =
    pname
    |> ignore(ws)
    |> ignore(alias_eq)
    |> ignore(ws)
    |> concat(parsec(:pfunc))
    |> reduce({:to_aliased, []})

  # --- Stages ---

  filter_stage =
    keyword.("filter")
    |> parsec({EctoQueryParser.Parser, :or_expr})
    |> reduce({:to_filter, []})

  select_item =
    ignore(ws)
    |> choice([aliased, pcol])
    |> ignore(ws)

  select_stage =
    keyword.("select")
    |> concat(select_item)
    |> repeat(ignore(string(",")) |> concat(select_item))
    |> reduce({:to_select, []})

  breakout =
    ignore(ws)
    |> choice([aliased, parsec(:pfunc), pcol])
    |> ignore(ws)

  agg_call =
    pname
    |> ignore(ws)
    |> ignore(string("("))
    |> ignore(ws)
    |> optional(pcol)
    |> ignore(ws)
    |> ignore(string(")"))
    |> post_traverse({:check_agg, []})

  agg =
    ignore(ws)
    |> concat(pname)
    |> ignore(ws)
    |> ignore(alias_eq)
    |> ignore(ws)
    |> concat(agg_call)
    |> ignore(ws)
    |> reduce({:to_agg, []})

  group_stage =
    keyword.("group")
    |> ignore(ws)
    |> optional(
      breakout
      |> repeat(ignore(string(",")) |> concat(breakout))
      |> tag(:breakouts)
    )
    |> ignore(string("{"))
    |> concat(agg)
    |> repeat(ignore(string(",")) |> concat(agg))
    |> ignore(string("}"))
    |> reduce({:to_group, []})

  sort_key =
    ignore(ws)
    |> optional(string("-") |> replace(:desc))
    |> concat(pcol)
    |> ignore(ws)
    |> reduce({:to_sort_key, []})

  sort_stage =
    keyword.("sort")
    |> concat(sort_key)
    |> repeat(ignore(string(",")) |> concat(sort_key))
    |> reduce({:to_sort, []})

  non_negative_integer = digits |> reduce({:to_count, []})

  limit_stage =
    keyword.("limit")
    |> ignore(ascii_string([?\s, ?\t, ?\n, ?\r], min: 1))
    |> concat(non_negative_integer)
    |> reduce({:to_limit, []})

  offset_stage =
    keyword.("offset")
    |> ignore(ascii_string([?\s, ?\t, ?\n, ?\r], min: 1))
    |> concat(non_negative_integer)
    |> reduce({:to_offset, []})

  # --- Source ---

  slug =
    ascii_char([?a..?z, ?0..?9])
    |> repeat(ascii_char([?a..?z, ?0..?9, ?-, ?_]))
    |> reduce({List, :to_string, []})

  at_ref =
    string("@")
    |> concat(slug)
    |> post_traverse({:tag_ref, []})

  table_ref =
    table_segment
    |> optional(string(".") |> concat(table_segment))
    |> reduce({Enum, :join, []})
    |> post_traverse({:tag_pos, [:table]})

  source =
    choice([at_ref, table_ref])
    |> label("a source (a table name or a @reference)")

  # --- Query ---

  bar = ignore(ws) |> ignore(string("|")) |> ignore(ws)

  stage =
    choice([
      filter_stage,
      select_stage,
      group_stage,
      sort_stage,
      limit_stage,
      offset_stage
    ])
    |> label("a stage (filter, select, group, sort, limit, or offset)")

  pipe_query =
    ignore(ws)
    |> concat(source)
    |> repeat(bar |> concat(stage))
    |> ignore(ws)

  # The label keeps failure messages to a single readable line; the
  # ParseError's line/column/rest carry the precise diagnostics.
  defparsec(:parse_raw, label(pipe_query, "a pipe query") |> eos())

  @doc """
  Parses a pipe query string into a `EctoQueryParser.Pipe.Query` struct.

  Returns `{:ok, %EctoQueryParser.Pipe.Query{}}` or
  `{:error, %EctoQueryParser.ParseError{}}`.
  """
  def parse(input) when is_binary(input) do
    case parse_raw(input) do
      {:ok, [source | stages], "", _context, _position, _byte_offset} ->
        {:ok, %EctoQueryParser.Pipe.Query{source: source, stages: stages}}

      {:ok, _, rest, _context, position, byte_offset} ->
        {:error,
         ParseError.from_nimble("unexpected input: #{inspect(rest)}", rest, position, byte_offset)}

      {:error, reason, rest, _context, position, byte_offset} ->
        {:error, ParseError.from_nimble(reason, rest, position, byte_offset)}
    end
  end

  # --- Traverse callbacks ---
  #
  # NimbleParsec reports line as {line, byte offset at which the line starts}
  # and offset as the position *after* the consumed input. All annotated
  # tokens are single-line ASCII, so the start position is recovered by
  # subtracting the token's byte size.

  @doc false
  def tag_pos(rest, [name], context, {line, line_start}, offset, tag) do
    start = offset - byte_size(name)
    pos = %{line: line, column: start - line_start + 1, offset: start}
    {rest, [{tag, name, pos}], context}
  end

  @doc false
  def kw_pos(rest, [kw], context, {line, line_start}, offset) do
    start = offset - byte_size(kw)
    pos = %{line: line, column: start - line_start + 1, offset: start}
    {rest, [pos], context}
  end

  @doc false
  def tag_ref(rest, [slug, "@"], context, {line, line_start}, offset) do
    start = offset - byte_size(slug) - 1
    pos = %{line: line, column: start - line_start + 1, offset: start}
    {rest, [{:ref, slug, pos}], context}
  end

  @doc false
  def check_agg(rest, args, context, _line, _offset) do
    {arg, {:pname, raw_name, _pos}} =
      case args do
        [{:pname, _, _} = name] -> {nil, name}
        [{:pcol, _, _} = col, {:pname, _, _} = name] -> {col, name}
      end

    name = String.downcase(raw_name)

    cond do
      name not in @agg_functions ->
        {:error,
         "unknown aggregation: #{raw_name} " <>
           "(expected count, count_distinct, sum, avg, min, or max)"}

      name != "count" and arg == nil ->
        {:error, "aggregation #{raw_name} requires a column argument"}

      true ->
        {rest, [{:agg_call, name, arg}], context}
    end
  end

  @doc false
  def to_pfunc([{:pname, name, pos} | args]), do: {:pfunc, String.downcase(name), pos, args}

  @doc false
  def to_aliased([{:pname, name, pos}, func]), do: {:aliased, name, pos, func}

  @doc false
  def to_filter([pos, ast]), do: {:filter, ast, pos}

  @doc false
  def to_select([pos | items]), do: {:select, items, pos}

  @doc false
  def to_group([pos | rest]) do
    {breakouts, aggs} =
      case rest do
        [{:breakouts, breakouts} | aggs] -> {breakouts, aggs}
        aggs -> {[], aggs}
      end

    {:group, breakouts, aggs, pos}
  end

  @doc false
  def to_agg([{:pname, alias_name, pos}, {:agg_call, fun, arg}]),
    do: {:agg, alias_name, pos, fun, arg}

  @doc false
  def to_sort([pos | keys]), do: {:sort, keys, pos}

  @doc false
  def to_sort_key([:desc, {:pcol, name, pos}]), do: {:key, :desc, name, pos}
  def to_sort_key([{:pcol, name, pos}]), do: {:key, :asc, name, pos}

  @doc false
  def to_count([digits]), do: String.to_integer(digits)

  @doc false
  def to_limit([pos, n]), do: {:limit, n, pos}

  @doc false
  def to_offset([pos, n]), do: {:offset, n, pos}
end
