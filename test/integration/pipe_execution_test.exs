defmodule EctoQueryParser.Integration.PipeExecutionTest do
  use ExUnit.Case

  @moduletag :integration

  import Ecto.Query, only: [from: 2]

  alias EctoQueryParser.TestRepo

  @allowed [
    name: :string,
    age: :integer,
    score: :float,
    status: :string,
    role: :string,
    created_at: :utc_datetime,
    performed_on: :date,
    author:
      {:belongs_to,
       table: "authors", owner_key: :author_id, related_key: :id, fields: [name: :string]}
  ]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    seed!()
    :ok
  end

  # Two roles with known aggregates:
  #   admin: ages 10, 20   (n=2, sum=30,  statuses: active/active → 1 distinct)
  #   user:  ages 30,40,50 (n=3, sum=120, statuses: active/banned/banned → 2 distinct)
  # created_at: admins in January, users in February.
  defp seed! do
    {2, [%{id: alice_id}, %{id: bob_id}]} =
      TestRepo.insert_all("authors", [%{name: "alice"}, %{name: "bob"}], returning: [:id])

    TestRepo.insert_all("test_items", [
      %{
        name: "a1",
        age: 10,
        status: "active",
        role: "admin",
        created_at: ~U[2026-01-05 12:00:00Z],
        author_id: alice_id
      },
      %{
        name: "a2",
        age: 20,
        status: "active",
        role: "admin",
        created_at: ~U[2026-01-20 12:00:00Z],
        author_id: alice_id
      },
      %{
        name: "u1",
        age: 30,
        status: "active",
        role: "user",
        created_at: ~U[2026-02-01 12:00:00Z],
        author_id: bob_id
      },
      %{
        name: "u2",
        age: 40,
        status: "banned",
        role: "user",
        created_at: ~U[2026-02-14 12:00:00Z],
        author_id: nil
      },
      %{
        name: "u3",
        age: 50,
        status: "banned",
        role: "user",
        created_at: ~U[2026-02-28 12:00:00Z],
        author_id: nil
      }
    ])

    :ok
  end

  defp run(text, opts \\ []) do
    {:ok, query, columns} =
      EctoQueryParser.build_pipe(text, Keyword.put_new(opts, :allowed_fields, @allowed))

    {TestRepo.all(query), columns}
  end

  # Renames positional rows (%{c0: _, ...}) back to their user-facing column
  # names — the workflow callers are expected to follow.
  defp run_named(text, opts \\ []) do
    {rows, columns} = run(text, opts)

    Enum.map(rows, fn row ->
      Map.new(columns, fn %{name: name, key: key} -> {name, Map.fetch!(row, key)} end)
    end)
  end

  describe "select and filter stages" do
    test "filter + select returns positional rows with a rename map" do
      rows = run_named("test_items | filter age >= 30 | select name, age")

      assert Enum.sort_by(rows, & &1["age"]) == [
               %{"name" => "u1", "age" => 30},
               %{"name" => "u2", "age" => 40},
               %{"name" => "u3", "age" => 50}
             ]
    end

    test "select aliases with functions execute" do
      rows = run_named(~s[test_items | filter name == "a1" | select upper_name = UPPER(name)])
      assert rows == [%{"upper_name" => "A1"}]
    end

    test "filter after select addresses the selected output only" do
      rows = run_named("test_items | select name, age | filter age > 45")
      assert rows == [%{"name" => "u3", "age" => 50}]
    end

    test "association joins execute in select and filter stages" do
      rows =
        run_named(
          ~s[test_items | filter author.name == "alice" | select name, author_name = LOWER(author.name)]
        )

      assert Enum.sort_by(rows, & &1["name"]) == [
               %{"name" => "a1", "author_name" => "alice"},
               %{"name" => "a2", "author_name" => "alice"}
             ]
    end
  end

  describe "group stage aggregations (executed for real)" do
    test "count, sum, avg, min, max, count_distinct with a breakout" do
      rows =
        run_named(
          "test_items | group role { n = count(), total = sum(age), average = avg(age), " <>
            "youngest = min(age), oldest = max(age), statuses = count_distinct(status) } " <>
            "| sort role"
        )

      assert [admin, user] = rows

      assert admin["role"] == "admin"
      assert admin["n"] == 2
      assert admin["total"] == 30
      assert admin["youngest"] == 10
      assert admin["oldest"] == 20
      assert admin["statuses"] == 1
      assert Decimal.equal?(admin["average"], Decimal.new(15))

      assert user["role"] == "user"
      assert user["n"] == 3
      assert user["total"] == 120
      assert user["youngest"] == 30
      assert user["oldest"] == 50
      assert user["statuses"] == 2
      assert Decimal.equal?(user["average"], Decimal.new(40))
    end

    test "group with no breakouts returns a single summary row" do
      assert [%{"n" => 5, "total" => 150}] =
               run_named("test_items | group { n = count(), total = sum(age) }")
    end

    test "count(col) counts non-null values" do
      # author_id is null for u2/u3
      assert [%{"with_author" => 3}] =
               run_named("test_items | group { with_author = count(author_id) }",
                 allowed_fields: [author_id: :integer]
               )
    end

    test "temporal bucketing via ROUND_MONTH executes" do
      rows =
        run_named(
          "test_items | group month = ROUND_MONTH(created_at) { n = count() } | sort month"
        )

      assert [%{"month" => jan, "n" => 2}, %{"month" => feb, "n" => 3}] = rows
      assert jan.year == 2026 and jan.month == 1 and jan.day == 1
      assert feb.year == 2026 and feb.month == 2 and feb.day == 1
    end

    test "filter after group is HAVING semantics" do
      rows = run_named("test_items | group role { total = sum(age) } | filter total > 100")
      assert rows == [%{"role" => "user", "total" => 120}]
    end

    test "aggregating over grouped output (group after group)" do
      # per-role sums (30, 120), then the max of those
      assert [%{"biggest" => 120}] =
               run_named(
                 "test_items | group role { total = sum(age) } | group { biggest = max(total) }"
               )
    end
  end

  describe "sort, limit, and offset stages" do
    test "sort on aggregation aliases, descending" do
      rows = run_named("test_items | group role { total = sum(age) } | sort -total")
      assert Enum.map(rows, & &1["total"]) == [120, 30]
    end

    test "sort with multiple keys and directions" do
      rows = run_named("test_items | select name, status, age | sort status, -age")

      assert Enum.map(rows, & &1["name"]) == ["u1", "a2", "a1", "u3", "u2"]
    end

    test "limit and offset apply to the sorted set" do
      rows = run_named("test_items | select name, age | sort age | limit 2 | offset 1")
      assert Enum.map(rows, & &1["name"]) == ["a2", "u1"]
    end

    test "limit after group limits the grouped rows" do
      rows = run_named("test_items | group role { total = sum(age) } | sort -total | limit 1")
      assert rows == [%{"role" => "user", "total" => 120}]
    end
  end

  describe "plural associations inside pipe filters" do
    test "EXISTS semantics execute against the real database" do
      allowed = [
        name: :string,
        posts:
          {:has_many,
           table: "test_items",
           owner_key: :id,
           related_key: :author_id,
           fields: [role: :string, name: :string]}
      ]

      rows =
        run_named(
          ~s[authors | filter posts.role == "admin" | group { n = count() }],
          allowed_fields: allowed
        )

      assert rows == [%{"n" => 1}]
    end
  end

  describe "parameters and literal_transform in pipe filters" do
    test "bound parameters execute" do
      rows =
        run_named("test_items | filter age >= {{min}} | select name | sort name",
          params: %{"min" => 40}
        )

      assert Enum.map(rows, & &1["name"]) == ["u2", "u3"]
    end

    test "optional groups prune and participate" do
      base = "test_items | filter role == {{role}} [[AND age >= {{min}}]] | group { n = count() }"

      assert [%{"n" => 3}] = run_named(base, params: %{"role" => "user"})
      assert [%{"n" => 2}] = run_named(base, params: %{"role" => "user", "min" => 40})
    end

    test "literal_transform ranges execute, including over grouped output" do
      transform = fn
        :utc_datetime, "january" ->
          {:range, {~U[2026-01-01 00:00:00Z], ~U[2026-01-31 23:59:59Z]}}

        _, _ ->
          :default
      end

      rows =
        run_named(~s[test_items | filter created_at == "january" | group { n = count() }],
          literal_transform: transform
        )

      assert rows == [%{"n" => 2}]

      # breakout columns keep their type, so the transform also fires on
      # filters over grouped output
      rows =
        run_named(
          ~s[test_items | group created_at { n = count() } | filter created_at == "january"],
          literal_transform: transform
        )

      assert length(rows) == 2
    end
  end

  describe "@slug sources" do
    defp resolver do
      fn
        "by-role" ->
          {:ok,
           from(t in "test_items",
             group_by: t.role,
             select: %{role: t.role, total: sum(t.age), n: count()}
           ), [role: :string, total: :integer, n: :integer]}

        _other ->
          {:error, "no such question"}
      end
    end

    test "filters and sorts run against the resolved subquery" do
      {:ok, query, nil} =
        EctoQueryParser.build_pipe("@by-role | filter total > 100 | sort -total",
          resolve_source: resolver()
        )

      assert [%{role: "user", total: 120, n: 3}] = TestRepo.all(query)
    end

    test "aggregating over a resolved source" do
      rows =
        run_named("@by-role | group { grand_total = sum(total) }", resolve_source: resolver())

      # sum over the subquery's bigint sum comes back as numeric
      assert [%{"grand_total" => grand_total}] = rows
      assert Decimal.equal?(grand_total, Decimal.new(150))
    end
  end

  describe "the full pipeline" do
    test "source | filter | group | sort | limit end to end" do
      text = """
      test_items
      | filter age <= 40
      | group role {
          total = sum(age),
          n = count()
        }
      | sort -total
      | limit 1
      """

      assert [%{"role" => "user", "total" => 70, "n" => 2}] = run_named(text)
    end
  end
end
