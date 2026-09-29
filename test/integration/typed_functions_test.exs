defmodule EctoQueryParser.Integration.TypedFunctionsTest do
  use ExUnit.Case

  @moduletag :integration

  import Ecto.Query, only: [select: 3]

  alias EctoQueryParser.TestRepo

  @allowed [
    name: :string,
    age: :integer,
    score: :float,
    status: :string,
    created_at: :utc_datetime,
    performed_on: :date
  ]

  # created_at is TIMESTAMP WITH TIME ZONE in the fixture schema; the sandbox
  # session runs in UTC. Instants are picked near midnight so zone
  # conversion moves them across a day boundary.
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    TestRepo.query!("SET TIME ZONE 'UTC'")

    TestRepo.insert_all("test_items", [
      %{
        name: "late",
        age: 42,
        score: 2.5,
        status: "7",
        created_at: ~U[2026-01-05 23:30:00Z],
        performed_on: ~D[2026-01-15]
      },
      %{
        name: "early",
        age: 43,
        score: 3.75,
        status: "12",
        created_at: ~U[2026-01-06 02:00:00Z],
        performed_on: ~D[2026-01-06]
      }
    ])

    :ok
  end

  defp rows(text, opts \\ []) do
    {:ok, query, columns} =
      EctoQueryParser.build_pipe(text, Keyword.put_new(opts, :allowed_fields, @allowed))

    names = Enum.map(columns || [], & &1.name)

    query
    |> TestRepo.all()
    |> Enum.map(fn row -> Enum.map(columns, &Map.fetch!(row, &1.key)) end)
    |> then(&{names, &1})
  end

  defp names(text, opts \\ []) do
    {_columns, rows} = rows(text <> " | select name | sort name", opts)
    List.flatten(rows)
  end

  describe "date" do
    test "compares against a date parameter" do
      assert names("test_items | filter date(created_at) == {{day}}",
               params: %{"day" => ~D[2026-01-05]}
             ) == ["late"]
    end

    test "with a zone, the local calendar day decides" do
      # 23:30 UTC on Jan 5 is already Jan 6 in Tokyo; 02:00 UTC on Jan 6 is
      # still Jan 5 in Chicago.
      assert names(~s[test_items | filter date(created_at, "Asia/Tokyo") == "2026-01-06"]) ==
               ["early", "late"]

      assert names(~s[test_items | filter date(created_at, "America/Chicago") == "2026-01-05"]) ==
               ["early", "late"]
    end

    test "groups by local day (the zone is inlined, so GROUP BY matches SELECT)" do
      assert {["day", "n"], rows} =
               rows(
                 ~s[test_items | group day = date(created_at, "America/Chicago") { n = count() } | sort day]
               )

      assert rows == [[~D[2026-01-05], 2]]
    end

    test "casts a string literal" do
      assert names(~s[test_items | filter performed_on == date("2026-01-06")]) == ["early"]
    end
  end

  describe "at_zone" do
    test "yields the local wall-clock time, which round_* buckets in" do
      assert {["name", "local"], rows} =
               rows(
                 ~s[test_items | select name, local = at_zone(created_at, "America/Chicago") | sort name]
               )

      assert rows == [
               ["early", ~N[2026-01-05 20:00:00.000000]],
               ["late", ~N[2026-01-05 17:30:00.000000]]
             ]

      assert {["local_day", "n"], [[local_day, 2]]} =
               rows(
                 ~s[test_items | group local_day = round_day(at_zone(created_at, "America/Chicago")) { n = count() }]
               )

      assert NaiveDateTime.to_date(local_day) == ~D[2026-01-05]
    end
  end

  describe "casts" do
    test "text, integer and number" do
      assert names(~s[test_items | filter text(age) == "42"]) == ["late"]
      assert names("test_items | filter integer(status) > 10") == ["early"]
      assert names(~s[test_items | filter integer("12") == integer(status)]) == ["early"]

      assert {["x"], [[x]]} =
               rows(~s[test_items | filter name == "early" | select x = number(score)])

      assert Decimal.equal?(x, Decimal.new("3.75"))
    end
  end

  describe "date parts" do
    test "extract as integers (weekday is ISO: Monday = 1)" do
      assert {["name", "y", "m", "d", "wd", "h"], rows} =
               rows(
                 "test_items | select name, y = year(created_at), m = month(created_at), " <>
                   "d = day(created_at), wd = weekday(created_at), h = hour(created_at) | sort name"
               )

      # 2026-01-05 is a Monday.
      assert rows == [["early", 2026, 1, 6, 2, 2], ["late", 2026, 1, 5, 1, 23]]
    end

    test "days_between counts calendar days from the first to the second" do
      assert {["name", "wait"], rows} =
               rows(
                 "test_items | select name, wait = days_between(created_at, performed_on) | sort name"
               )

      assert rows == [["early", 0], ["late", 10]]
    end
  end

  describe "date() compared to constant dates" do
    # Each rewritten filter must select exactly what the cast would have.
    defp cast_names(sql_where, params) do
      %{rows: rows} =
        TestRepo.query!(
          "SELECT name FROM test_items WHERE #{sql_where} ORDER BY name",
          params
        )

      List.flatten(rows)
    end

    test "results match the cast, for every operator" do
      for {op, sql_op} <- [
            {"==", "="},
            {"!=", "<>"},
            {">=", ">="},
            {">", ">"},
            {"<=", "<="},
            {"<", "<"}
          ] do
        assert names(~s[test_items | filter date(created_at) #{op} "2026-01-05"]) ==
                 cast_names("created_at::date #{sql_op} DATE '2026-01-05'", []),
               "operator #{op}"

        assert names(
                 ~s[test_items | filter date(created_at, "America/Chicago") #{op} "2026-01-05"]
               ) ==
                 cast_names(
                   "(created_at AT TIME ZONE 'America/Chicago')::date #{sql_op} DATE '2026-01-05'",
                   []
                 ),
               "zoned operator #{op}"
      end
    end

    test "the plan can use an index on the column" do
      {:ok, query, _} =
        EctoQueryParser.build_pipe(
          ~s[test_items | filter date(created_at, "America/Chicago") == {{day}}],
          allowed_fields: @allowed,
          params: %{"day" => ~D[2026-01-05]}
        )

      query = select(query, [t], field(t, :name))
      {sql, params} = Ecto.Adapters.SQL.to_sql(:all, TestRepo, query)

      # Tiny tables always seq-scan by cost; forbid it so the planner shows
      # whether an index scan is possible at all.
      TestRepo.query!("SET LOCAL enable_seqscan = off")
      %{rows: plan} = TestRepo.query!("EXPLAIN " <> sql, params)
      plan = Enum.map_join(plan, "\n", &hd/1)

      assert plan =~ "test_items_created_at_index"
    end
  end
end
