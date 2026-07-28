defmodule EctoQueryParser.ValidationError do
  @moduledoc """
  Exception struct returned (inside an `{:error, _}` tuple) when a pipe query
  parses but fails stage-level validation — an unknown column in a `select`
  or `sort`, an aggregation alias colliding with a breakout, an unresolvable
  `@reference`, and so on.

  Where the offending token's source position is known (identifiers, aliases,
  and stage keywords in the pipe grammar carry positions through the AST),
  the struct includes it so editors can underline the token:

    * `:message` - human-readable description of what went wrong
    * `:line` - 1-based line number of the offending token (or `nil`)
    * `:column` - 1-based column number of the offending token (or `nil`)
    * `:byte_offset` - 0-based byte offset of the offending token (or `nil`)
    * `:stage` - which part of the query failed (`"source"`, `"filter"`,
      `"select"`, `"group"`, `"sort"`, `"limit"`, `"offset"`)
    * `:stage_index` - 1-based position of the stage in the pipe
      (`nil` for the source)

  Validation errors arising *inside* a `filter` stage's boolean expression
  (unknown field, unbound parameter, …) reuse the existing filter builder and
  therefore keep their plain `{:error, binary}` shape, prefixed with the
  stage that produced them — the filter grammar's AST does not carry
  per-token positions.
  """

  defexception [:message, :line, :column, :byte_offset, :stage, :stage_index]

  @type t :: %__MODULE__{
          message: String.t(),
          line: pos_integer() | nil,
          column: pos_integer() | nil,
          byte_offset: non_neg_integer() | nil,
          stage: String.t(),
          stage_index: pos_integer() | nil
        }

  @impl Exception
  def message(%__MODULE__{} = error) do
    where =
      if error.stage_index,
        do: "in #{error.stage} stage #{error.stage_index}",
        else: "in the #{error.stage}"

    position =
      if error.line,
        do: " at line #{error.line}, column #{error.column}",
        else: ""

    "invalid query#{position} (#{where}): #{error.message}"
  end
end
