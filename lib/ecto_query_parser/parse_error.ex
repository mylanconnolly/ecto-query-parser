defmodule EctoQueryParser.ParseError do
  @moduledoc """
  Exception struct returned (inside an `{:error, _}` tuple) when a query
  string fails to parse.

  Carries enough position information to power editor diagnostics:

    * `:message` - human-readable description of what went wrong
    * `:line` - 1-based line number where parsing stopped
    * `:column` - 1-based column number where parsing stopped
    * `:byte_offset` - 0-based byte offset into the input where parsing stopped
    * `:rest` - the unconsumed remainder of the input (truncated)

  Because this is an `Exception`, `Exception.message/1` produces a one-line
  summary including the position, and the struct can be raised directly.

  Note that only parse-stage failures return this struct; builder/validation
  errors (unknown field, field not allowed, etc.) keep their `{:error, binary}`
  shape since no source position is available at that stage.
  """

  defexception [:message, :line, :column, :byte_offset, :rest]

  @type t :: %__MODULE__{
          message: String.t(),
          line: pos_integer(),
          column: pos_integer(),
          byte_offset: non_neg_integer(),
          rest: String.t()
        }

  @impl Exception
  def message(%__MODULE__{message: message, line: line, column: column}) do
    "parse error at line #{line}, column #{column}: #{message}"
  end
end
