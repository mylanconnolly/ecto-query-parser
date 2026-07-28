defmodule EctoQueryParser.PipeTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias EctoQueryParser.{ParseError, ValidationError}
  alias EctoQueryParser.Pipe.Query, as: PipeQuery

  @allowed [
    name: :string,
    age: :integer,
    status: :string,
    amount: :integer,
    region: :string,
    created_at: :utc_datetime,
    performed_on: :date
  ]

  defp parse(text), do: EctoQueryParser.parse_pipe(text)

  defp build(text, opts \\ []) do
    EctoQueryParser.build_pipe(text, Keyword.put_new(opts, :allowed_fields, @allowed))
  end

  defp sql(text, opts \\ []) do
    {:ok, query, _columns} = build(text, opts)
    inspect(query)
  end

  # --- Grammar: sources ---

  describe "sources" do
    test "bare table source is a valid query" do
      assert {:ok, %PipeQuery{source: {:table, "orders", pos}, stages: []}} = parse("orders")
      assert pos == %{line: 1, column: 1, offset: 0}
    end

    test "schema-qualified table source" do
      assert {:ok, %PipeQuery{source: {:table, "sales.orders", _}}} = parse("sales.orders")
    end

    test "schema qualifier sets the query prefix" do
      {:ok, query, nil} = build("sales.orders")
      assert query.from.prefix == "sales"
    end

    test "@slug source" do
      assert {:ok, %PipeQuery{source: {:ref, "monthly-revenue_2", pos}}} =
               parse("@monthly-revenue_2")

      assert pos == %{line: 1, column: 1, offset: 0}
    end

    test "slugs must start with a lowercase letter or digit" do
      assert {:error, %ParseError{column: 1}} = parse("@Foo")
      assert {:error, %ParseError{}} = parse("@-foo")
    end

    test "surrounding whitespace is tolerated" do
      assert {:ok, %PipeQuery{source: {:table, "orders", _}}} = parse("  orders  ")
    end

    test "empty input is a parse error" do
      assert {:error, %ParseError{line: 1, column: 1}} = parse("")
    end
  end

  # --- Grammar: stages ---

  describe "filter stage" do
    test "embeds the existing filter grammar verbatim" do
      assert {:ok, %PipeQuery{stages: [{:filter, ast, _pos}]}} =
               parse(~s[orders | filter status == "paid" AND NOT age < 18])

      assert {:and, [{:op, :==, _, _}, {:not, {:op, :<, _, _}}]} = ast
    end

    test "parameters and optional groups parse inside filter stages" do
      assert {:ok, %PipeQuery{stages: [{:filter, ast, _}]}} =
               parse("orders | filter status == {{s}} [[AND age >= {{min}}]]")

      assert {:and, [{:op, :==, _, {:param, "s"}}, {:optional, :and, _}]} = ast
    end

    test "multiple filter stages are allowed" do
      assert {:ok, %PipeQuery{stages: [{:filter, _, _}, {:filter, _, _}]}} =
               parse("orders | filter age > 1 | filter age < 9")
    end

    test "a pipe inside a string literal is not a stage separator" do
      assert {:ok, %PipeQuery{stages: [{:filter, {:op, :==, _, {:string, "a|b"}}, _}, _]}} =
               parse(~s[orders | filter name == "a|b" | limit 1])
    end
  end

  describe "select stage" do
    test "plain columns and aliased functions" do
      assert {:ok, %PipeQuery{stages: [{:select, items, _}]}} =
               parse("orders | select name, customer.region, upper_name = UPPER(name)")

      assert [
               {:pcol, "name", _},
               {:pcol, "customer.region", _},
               {:aliased, "upper_name", _, {:pfunc, "upper", _, [{:pcol, "name", _}]}}
             ] = items
    end

    test "function arguments may be literals and nested functions" do
      assert {:ok, %PipeQuery{stages: [{:select, [{:aliased, "x", _, func}], _}]}} =
               parse(~s[orders | select x = COALESCE(TRIM(name), "n/a")])

      assert {:pfunc, "coalesce", _, [{:pfunc, "trim", _, _}, {:string, "n/a"}]} = func
    end

    test "select with no items is a parse error" do
      assert {:error, %ParseError{}} = parse("orders | select")
    end

    test "an unaliased function is a parse error" do
      assert {:error, %ParseError{}} = parse("orders | select UPPER(name)")
    end
  end

  describe "group stage" do
    test "breakouts and aggregations" do
      assert {:ok, %PipeQuery{stages: [{:group, breakouts, aggs, _}]}} =
               parse(
                 "orders | group region, ROUND_MONTH(created_at) { total = sum(amount), n = count() }"
               )

      assert [{:pcol, "region", _}, {:pfunc, "round_month", _, [{:pcol, "created_at", _}]}] =
               breakouts

      assert [
               {:agg, "total", _, "sum", {:pcol, "amount", _}},
               {:agg, "n", _, "count", nil}
             ] = aggs
    end

    test "all aggregation functions parse" do
      text =
        "orders | group { a = count(), b = count(x), c = count_distinct(x), " <>
          "d = sum(x), e = avg(x), f = min(x), g = max(x) }"

      assert {:ok, %PipeQuery{stages: [{:group, [], aggs, _}]}} = parse(text)

      assert Enum.map(aggs, fn {:agg, _, _, fun, _} -> fun end) ==
               ~w(count count count_distinct sum avg min max)
    end

    test "aggregation names are case-insensitive" do
      assert {:ok, %PipeQuery{stages: [{:group, [], [{:agg, "t", _, "sum", _}], _}]}} =
               parse("orders | group { t = SUM(amount) }")
    end

    test "group with no breakouts is a single-row summary" do
      assert {:ok, %PipeQuery{stages: [{:group, [], [_], _}]}} =
               parse("orders | group { n = count() }")
    end

    test "breakouts may be aliased function applications" do
      assert {:ok, %PipeQuery{stages: [{:group, [{:aliased, "month", _, _}], _, _}]}} =
               parse("orders | group month = ROUND_MONTH(created_at) { n = count() }")
    end

    test "unknown aggregation is a parse error with a helpful message" do
      assert {:error, %ParseError{message: message}} =
               parse("orders | group { m = median(age) }")

      assert message =~ "unknown aggregation: median"
    end

    test "aggregations other than count require a column argument" do
      assert {:error, %ParseError{message: message}} = parse("orders | group { t = sum() }")
      assert message =~ "sum requires a column argument"
    end

    test "unaliased aggregations are a parse error" do
      assert {:error, %ParseError{}} = parse("orders | group { count() }")
    end

    test "missing braces are a parse error" do
      assert {:error, %ParseError{}} = parse("orders | group region")
    end
  end

  describe "sort stage" do
    test "ascending and descending keys" do
      assert {:ok, %PipeQuery{stages: [{:sort, keys, _}]}} =
               parse("orders | sort -total, customer.region")

      assert [{:key, :desc, "total", _}, {:key, :asc, "customer.region", _}] = keys
    end

    test "a bare dash is a parse error" do
      assert {:error, %ParseError{}} = parse("orders | sort -")
    end
  end

  describe "limit and offset stages" do
    test "non-negative integer literals" do
      assert {:ok, %PipeQuery{stages: [{:limit, 10, _}, {:offset, 0, _}]}} =
               parse("orders | limit 10 | offset 0")
    end

    test "negative numbers are a parse error" do
      assert {:error, %ParseError{}} = parse("orders | limit -1")
    end

    test "parameters are not accepted" do
      assert {:error, %ParseError{}} = parse("orders | limit {{n}}")
    end
  end

  describe "grammar shape" do
    test "whitespace and newlines are insignificant around pipes" do
      text = """
      orders
        | filter status == "paid"
        |   group region {
              total = sum(amount),
              n     = count()
            }
        | sort -total
        | limit 10
      """

      assert {:ok, %PipeQuery{stages: stages}} = parse(text)
      assert Enum.map(stages, &elem(&1, 0)) == [:filter, :group, :sort, :limit]
    end

    test "stage keywords are lowercase" do
      assert {:error, %ParseError{}} = parse("orders | FILTER age > 1")
    end

    test "unknown stage keyword is a positioned parse error" do
      assert {:error, %ParseError{line: 1, column: 8, rest: rest}} =
               parse("orders | flter age > 1")

      assert rest =~ "| flter"
    end

    test "trailing pipe is a parse error" do
      assert {:error, %ParseError{}} = parse("orders |")
    end

    test "malformed stage positions point into multiline input" do
      assert {:error, %ParseError{line: 2, column: 3}} =
               parse("orders\n  | sort -")
    end

    test "token positions are recorded on stage keywords, aliases, and columns" do
      {:ok, %PipeQuery{stages: [{:group, [breakout], [agg], group_pos}]}} =
        parse("orders | group region { total = sum(amount) }")

      assert group_pos == %{line: 1, column: 10, offset: 9}
      assert {:pcol, "region", %{line: 1, column: 16, offset: 15}} = breakout
      assert {:agg, "total", %{line: 1, column: 25, offset: 24}, "sum", arg} = agg
      assert {:pcol, "amount", %{line: 1, column: 37, offset: 36}} = arg
    end
  end

  # --- parameters/1 on pipe texts ---

  describe "parameters/1 with pipe queries" do
    test "collects parameters across filter stages in order of first appearance" do
      assert {:ok, params} =
               EctoQueryParser.parameters(
                 "orders | filter status == {{s}} [[AND age >= {{min}}]] | filter name == {{s}}"
               )

      assert params == [
               %{name: "s", required: true},
               %{name: "min", required: false}
             ]
    end

    test "a parameter optional in one stage but required in another is required" do
      assert {:ok, [%{name: "p", required: true}]} =
               EctoQueryParser.parameters(
                 "orders | filter [[age >= {{p}}]] | filter age <= {{p}}"
               )
    end

    test "accepts an already-parsed pipe query" do
      {:ok, pipe} = parse("orders | filter status == {{s}}")
      assert {:ok, [%{name: "s", required: true}]} = EctoQueryParser.parameters(pipe)
    end

    test "a pipe with no filter stages has no parameters" do
      assert {:ok, []} = EctoQueryParser.parameters("orders | limit 5")
    end

    test "reports the parse error of whichever grammar consumed more input" do
      # Fails both grammars; the pipe parse gets past "orders | filter x "
      # while the filter parse stops at the first "|".
      assert {:error, %ParseError{byte_offset: offset}} =
               EctoQueryParser.parameters("orders | filter x == | limit 2")

      assert offset > 7
    end
  end

  # --- Compilation: shape ---

  describe "build_pipe/2 basics" do
    test "bare table source compiles to a schemaless from with nil columns" do
      assert {:ok, query, nil} = build("orders")
      assert inspect(query) =~ ~s(from o0 in "orders")
    end

    test "filter stages compile through the existing filter machinery" do
      out = sql(~s[orders | filter status == "paid" AND age >= 18])
      assert out =~ ~s[where: o0.status == ^"paid" and o0.age >= ^18]
    end

    test "select projects into positional keys and returns the column mapping" do
      assert {:ok, query, columns} = build("orders | select name, age")
      assert columns == [%{name: "name", key: :c0}, %{name: "age", key: :c1}]
      assert inspect(query) =~ "select: %{c0: o0.name, c1: o0.age}"
    end

    test "consecutive filters merge into one query level" do
      out = sql("orders | filter age > 1 | filter age < 9")
      refute out =~ "subquery"
    end

    test "type coercion applies inside pipe filters" do
      out = sql(~s[orders | filter performed_on >= "2026-05-20"])
      assert out =~ "type(^\"2026-05-20\", :date)"
    end

    test "association paths join in base-context stages" do
      allowed = [
        author:
          {:belongs_to,
           table: "authors", owner_key: :author_id, related_key: :id, fields: [name: :string]}
      ]

      out =
        sql(~s[orders | filter author.name == "alice" | select author.name],
          allowed_fields: allowed
        )

      assert out =~ ~s[join: a1 in "authors"]
      assert out =~ "select: %{c0: a1.name}"
    end

    test "plural associations compile to EXISTS inside pipe filters" do
      allowed = [
        comments:
          {:has_many,
           table: "comments", owner_key: :id, related_key: :post_id, fields: [body: :string]}
      ]

      out = sql(~s[orders | filter comments.body contains "ship"], allowed_fields: allowed)
      assert out =~ "exists("
      assert out =~ ~s[from c0 in "comments"]
    end
  end

  describe "staged compilation and subquery wrapping" do
    test "filter after group wraps in a subquery (HAVING semantics)" do
      out = sql("orders | group region { total = sum(amount) } | filter total > 100")
      assert out =~ "from o0 in subquery("
      assert out =~ "where: o0.c1 > ^100"
    end

    test "sort after group addresses grouped output including aliases" do
      out = sql("orders | group region { total = sum(amount) } | sort -total, region")
      assert out =~ "order_by: [desc: o0.c1, asc: o0.c0]"
    end

    test "filter, sort, and limit after group share one wrapped level" do
      out =
        sql(
          "orders | group region { total = sum(amount) } | filter total > 100 | sort -total | limit 5"
        )

      # exactly one wrap: the grouped query is the only subquery
      assert length(String.split(out, "subquery(")) == 2
      assert out =~ "limit: ^5"
    end

    test "filter after select addresses the selected output" do
      out = sql("orders | select name, age | filter age > 21")
      assert out =~ "from o0 in subquery("
      assert out =~ "where: o0.c1 > ^21"
    end

    test "filter after select cannot reference unselected columns" do
      assert {:error, message} = build("orders | select name | filter age > 21")
      assert message == "in filter stage 2: unknown column: age (output columns: name)"
    end

    test "sort after select cannot reference unselected columns" do
      assert {:error, %ValidationError{} = error} = build("orders | select name | sort age")
      assert error.stage == "sort"
      assert error.stage_index == 2
      assert error.message =~ "unknown column: age"
      assert error.column == 29
    end

    test "select after group re-projects the grouped output" do
      assert {:ok, query, columns} =
               build("orders | group region { total = sum(amount), n = count() } | select total")

      assert columns == [%{name: "total", key: :c0}]
      assert inspect(query) =~ "select: %{c0: o0.c1}"
    end

    test "a second sort replaces the first" do
      out = sql("orders | sort name | sort age")
      refute out =~ "o0.name"
      assert out =~ "order_by: [asc: o0.age]"
    end

    test "limit after group applies to the grouped level" do
      out = sql("orders | group region { n = count() } | limit 3")
      refute out =~ "subquery"
      assert out =~ "limit: ^3"
    end

    test "column stages after limit re-wrap the projected level" do
      out = sql("orders | group { n = count() } | filter n > 1 | limit 2 | sort n")
      # two wraps: one for the filter, one for the sort after limit
      assert length(String.split(out, "subquery(")) == 3
    end

    test "grouped output names carry their types into later filters" do
      transform = fn
        :date, "last year" -> {:range, {~D[2025-01-01], ~D[2025-12-31]}}
        _, _ -> :default
      end

      out =
        sql(
          ~s[orders | group performed_on { n = count() } | filter performed_on == "last year"],
          literal_transform: transform
        )

      assert out =~ "o0.c0 >= ^~D[2025-01-01] and o0.c0 <= ^~D[2025-12-31]"
    end
  end

  describe "group stage compilation" do
    test "breakouts then aliases, in order" do
      assert {:ok, query, columns} =
               build("orders | group region, status { total = sum(amount), n = count() }")

      assert columns == [
               %{name: "region", key: :c0},
               %{name: "status", key: :c1},
               %{name: "total", key: :c2},
               %{name: "n", key: :c3}
             ]

      out = inspect(query)
      assert out =~ "group_by: [o0.region, o0.status]"
      assert out =~ "select: %{c0: o0.region, c1: o0.status, c2: sum(o0.amount), c3: count()}"
    end

    test "group with no breakouts emits no group_by" do
      out = sql("orders | group { n = count() }")
      refute out =~ "group_by"
      assert out =~ "select: %{c0: count()}"
    end

    test "count_distinct compiles to count(..., :distinct)" do
      out = sql("orders | group { u = count_distinct(status) }")
      assert out =~ "count(o0.status, :distinct)"
    end

    test "temporal bucketing breakouts get a derived, referenceable name" do
      assert {:ok, _query, columns} =
               build(
                 "orders | group ROUND_MONTH(created_at) { n = count() } | sort round_month_created_at"
               )

      assert [%{name: "round_month_created_at", key: :c0}, %{name: "n", key: :c1}] = columns
    end

    test "aliased breakouts are referenceable by their alias" do
      out = sql("orders | group month = ROUND_MONTH(created_at) { n = count() } | sort -month")
      assert out =~ "order_by: [desc: o0.c0]"
    end
  end

  # --- Validation errors ---

  describe "positioned validation errors" do
    test "unknown column in select carries the token position" do
      assert {:error, %ValidationError{} = error} = build("orders | select name, balance")
      assert error.stage == "select"
      assert error.stage_index == 1
      assert error.message == "field not allowed: balance"
      assert {error.line, error.column, error.byte_offset} == {1, 23, 22}
    end

    test "Exception.message includes position and stage" do
      assert {:error, error} = build("orders | select balance")

      assert Exception.message(error) ==
               "invalid query at line 1, column 17 (in select stage 1): field not allowed: balance"
    end

    test "aggregation argument errors point at the argument" do
      assert {:error, %ValidationError{} = error} =
               build("orders | group region { t = sum(balance) }")

      assert error.stage == "group"
      assert error.message == "field not allowed: balance"
      assert error.column == 33
    end

    test "alias collisions point at the colliding alias" do
      assert {:error, %ValidationError{} = error} =
               build("orders | group region { region = count() }")

      assert error.message == "duplicate output column: region"
      assert error.column == 25
    end

    test "duplicate aggregation aliases collide" do
      assert {:error, %ValidationError{message: message}} =
               build("orders | group { n = count(), n = sum(amount) }")

      assert message == "duplicate output column: n"
    end

    test "duplicate select columns collide" do
      assert {:error, %ValidationError{message: message}} = build("orders | select name, name")
      assert message == "duplicate output column: name"
    end

    test "plural association paths are rejected outside filters" do
      allowed = [
        comments:
          {:has_many,
           table: "comments", owner_key: :id, related_key: :post_id, fields: [body: :string]}
      ]

      assert {:error, %ValidationError{} = error} =
               build("orders | select comments.body", allowed_fields: allowed)

      assert error.message =~ "plural association path comments.body"
      assert error.column == 17
    end

    test "filter after limit on an unprojected source is rejected" do
      assert {:error, %ValidationError{} = error} = build("orders | limit 5 | filter age > 1")
      assert error.stage == "filter"
      assert error.stage_index == 2
      assert error.message =~ "cannot follow limit/offset"
    end

    test "at most one limit stage" do
      assert {:error, %ValidationError{} = error} = build("orders | limit 1 | limit 2")
      assert error.stage == "limit"
      assert error.stage_index == 2
      assert error.message == "at most one limit stage is allowed"
    end

    test "at most one offset stage" do
      assert {:error, %ValidationError{message: message}} =
               build("orders | offset 1 | offset 2")

      assert message == "at most one offset stage is allowed"
    end

    test "filter-internal errors keep the plain binary shape, prefixed with the stage" do
      assert {:error, "in filter stage 1: field not allowed: balance"} =
               build("orders | filter balance == 1")
    end

    test "unbound required parameters error with the stage prefix" do
      assert {:error, "in filter stage 1: missing required parameter: min"} =
               build("orders | filter age >= {{min}}")
    end
  end

  # --- Parameters and optional groups at build time ---

  describe "parameters in pipe filters" do
    test "bound parameters compile like inline literals" do
      out = sql("orders | filter status == {{s}}", params: %{"s" => "paid"})
      assert out =~ ~s[where: o0.status == ^"paid"]
    end

    test "optional groups prune when unbound" do
      out = sql("orders | filter status == \"live\" [[AND age >= {{min}}]]", params: %{})
      refute out =~ "age"
      assert out =~ ~s[where: o0.status == ^"live"]
    end

    test "optional groups participate when bound" do
      out =
        sql("orders | filter status == \"live\" [[AND age >= {{min}}]]",
          params: %{"min" => 21}
        )

      assert out =~ "o0.age >= ^21"
    end

    test "a fully pruned filter degenerates to WHERE TRUE" do
      out = sql("orders | filter [[age >= {{min}}]] | select name", params: %{})
      assert out =~ "where: ^true"
    end
  end

  describe "literal_transform in pipe filters" do
    test "applies against base-context field types" do
      transform = fn
        :date, "today" -> {:ok, ~D[2026-07-28]}
        _, _ -> :default
      end

      out = sql(~s[orders | filter performed_on == "today"], literal_transform: transform)
      assert out =~ "o0.performed_on == ^~D[2026-07-28]"
    end

    test "range results expand per operator" do
      transform = fn
        :date, "last year" -> {:range, {~D[2025-01-01], ~D[2025-12-31]}}
        _, _ -> :default
      end

      out = sql(~s[orders | filter performed_on == "last year"], literal_transform: transform)
      assert out =~ "o0.performed_on >= ^~D[2025-01-01] and o0.performed_on <= ^~D[2025-12-31]"
    end
  end

  # --- @slug sources ---

  describe "@slug resolution" do
    defp resolver(_opts \\ []) do
      fn
        "monthly-revenue" ->
          {:ok,
           from(t in "orders",
             group_by: t.region,
             select: %{region: t.region, total: sum(t.amount)}
           ), [region: :string, total: :integer]}

        "broken" ->
          {:error, "no such question"}

        "bad-contract" ->
          {:ok, :nope}
      end
    end

    test "the resolved queryable becomes a subquery source with its field spec" do
      assert {:ok, query, nil} =
               EctoQueryParser.build_pipe(
                 "@monthly-revenue | filter total > 100 | sort -total",
                 resolve_source: resolver()
               )

      out = inspect(query)
      assert out =~ "from o0 in subquery("
      assert out =~ "where: o0.total > ^100"
      assert out =~ "order_by: [desc: o0.total]"
    end

    test "filters validate against the resolved field spec" do
      assert {:error, "in filter stage 1: field not allowed: balance"} =
               EctoQueryParser.build_pipe("@monthly-revenue | filter balance == 1",
                 resolve_source: resolver()
               )
    end

    test "stages can project and aggregate over the resolved source" do
      assert {:ok, _query, columns} =
               EctoQueryParser.build_pipe(
                 "@monthly-revenue | group { grand_total = sum(total) }",
                 resolve_source: resolver()
               )

      assert columns == [%{name: "grand_total", key: :c0}]
    end

    test "a @slug without a resolver is a positioned build error" do
      assert {:error, %ValidationError{} = error} =
               EctoQueryParser.build_pipe("@monthly-revenue | limit 3")

      assert error.stage == "source"
      assert error.stage_index == nil
      assert {error.line, error.column} == {1, 1}
      assert error.message =~ "no :resolve_source option"
    end

    test "resolver errors surface with the source position" do
      assert {:error, %ValidationError{} = error} =
               EctoQueryParser.build_pipe("@broken | limit 3", resolve_source: resolver())

      assert error.message == "cannot resolve @broken: no such question"
      assert error.column == 1
    end

    test "resolvers must honor the contract" do
      assert {:error, %ValidationError{message: message}} =
               EctoQueryParser.build_pipe("@bad-contract | limit 3", resolve_source: resolver())

      assert message =~ "resolve_source must return {:ok, queryable, fields} or {:error, message}"
    end

    test "resolve_source must be a 1-arity function" do
      assert {:error, message} =
               EctoQueryParser.build_pipe("@monthly-revenue", resolve_source: :nope)

      assert message =~ "resolve_source must be a 1-arity function"
    end
  end

  # --- Column budget ---

  describe "column budget" do
    test "a projection may produce at most 64 columns" do
      aggs = Enum.map_join(1..65, ", ", fn i -> "a#{i} = count()" end)

      assert {:error, %ValidationError{message: message}} =
               build("orders | group { #{aggs} }")

      assert message == "a stage may produce at most 64 columns, got 65"
    end

    test "64 columns are accepted" do
      aggs = Enum.map_join(1..64, ", ", fn i -> "a#{i} = count()" end)
      assert {:ok, _query, columns} = build("orders | group { #{aggs} }")
      assert length(columns) == 64
      assert List.last(columns) == %{name: "a64", key: :c63}
    end
  end

  # --- build_pipe input flexibility ---

  describe "build_pipe/2 inputs" do
    test "accepts an already-parsed pipe query" do
      {:ok, pipe} = parse("orders | select name")
      assert {:ok, _query, [%{name: "name", key: :c0}]} = build(pipe)
    end

    test "propagates parse errors" do
      assert {:error, %ParseError{}} = build("orders | flter x")
    end
  end
end
