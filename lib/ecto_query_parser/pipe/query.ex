defmodule EctoQueryParser.Pipe.Query do
  @moduledoc """
  A parsed pipe query: a source plus an ordered list of stages.

  Returned by `EctoQueryParser.parse_pipe/1` and accepted by
  `EctoQueryParser.build_pipe/2`. The `:source` is one of:

    * `{:table, name, pos}` — a table reference, optionally schema-qualified
      (`"orders"`, `"sales.orders"`).
    * `{:ref, slug, pos}` — an external `@slug` reference, resolved at build
      time via the `:resolve_source` option.

  Callers that need to validate the table a query addresses (e.g. against a
  catalog of exposed tables) should parse first, inspect `:source`, and only
  then build with the field spec for that table.

  Stage tuples (`:stages`) and the `pos` maps (`%{line: l, column: c,
  offset: o}`, all referring to the token's start) are considered
  implementation detail; their shape may change between minor versions.
  """

  defstruct [:source, stages: []]

  @type pos :: %{line: pos_integer(), column: pos_integer(), offset: non_neg_integer()}
  @type source :: {:table, String.t(), pos()} | {:ref, String.t(), pos()}
  @type t :: %__MODULE__{source: source(), stages: [tuple()]}
end
