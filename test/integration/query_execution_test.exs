defmodule EctoQueryParser.Integration.QueryExecutionTest do
  use ExUnit.Case

  @moduletag :integration

  alias EctoQueryParser.TestRepo
  alias EctoQueryParser.Test.TestSchema

  import Ecto.Query, only: [from: 2]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
  end

  defp run(query_string, opts \\ []) do
    {:ok, query} = EctoQueryParser.apply(TestSchema, query_string, opts)
    TestRepo.all(query)
  end

  defp run_schemaless(query_string, opts) do
    base = from(t in "test_items", select: %{id: t.id})
    {:ok, query} = EctoQueryParser.apply(base, query_string, opts)
    TestRepo.all(query)
  end

  # -- Basic operators --

  describe "basic operators" do
    test "== with string" do
      assert run(~s{name == "alice"}) == []
    end

    test "== with integer" do
      assert run("age == 42") == []
    end

    test "== with float" do
      assert run("score == 3.14") == []
    end

    test "== with boolean" do
      assert run("active == true") == []
    end

    test "!= operator" do
      assert run(~s{status != "banned"}) == []
    end

    test ">= operator" do
      assert run("age >= 18") == []
    end

    test "<= operator" do
      assert run("score <= 9.99") == []
    end
  end

  # -- Text operators --

  describe "text operators" do
    test "contains with string literal" do
      assert run(~s{name contains "alice"}) == []
    end

    test "contains with identifier" do
      assert run(~s{name contains role}) == []
    end

    test "like" do
      assert run(~s{name like "%alice%"}) == []
    end

    test "ilike" do
      assert run(~s{name ilike "%ALICE%"}) == []
    end

    test "search with single word" do
      assert run(~s{body search "elixir"}) == []
    end

    test "search with multiple words" do
      assert run(~s{body search "elixir programming"}) == []
    end

    test "search with empty string" do
      assert run(~s{body search ""}) == []
    end
  end

  # -- Includes (array) --

  describe "includes operator" do
    test "includes with string value" do
      assert run(~s{tags includes "elixir"}) == []
    end
  end

  # -- String functions --

  describe "string functions" do
    test "UPPER" do
      assert run(~s{UPPER(name) == "ALICE"}) == []
    end

    test "LOWER" do
      assert run(~s{LOWER(name) == "alice"}) == []
    end

    test "TRIM" do
      assert run(~s{TRIM(name) == "alice"}) == []
    end

    test "CONCAT" do
      assert run(~s{CONCAT(name, role) == "aliceadmin"}) == []
    end

    test "REPLACE" do
      assert run(~s{REPLACE(name, "alice", "bob") == "bob"}) == []
    end

    test "nested functions" do
      assert run(~s{UPPER(TRIM(name)) == "ALICE"}) == []
    end
  end

  # -- Math functions --

  describe "math functions" do
    test "ABS" do
      assert run(~s{ABS(age) >= 5}) == []
    end

    test "FLOOR" do
      assert run(~s{FLOOR(score) == 3}) == []
    end

    test "CEIL" do
      assert run(~s{CEIL(score) == 4}) == []
    end
  end

  # -- Date/time functions (using created_at timestamp column) --

  describe "date/time functions" do
    test "NOW() comparison" do
      assert run(~s{NOW() >= NOW()}) == []
    end

    test "ROUND_SECOND" do
      assert run(~s{ROUND_SECOND(created_at) == NOW()}) == []
    end

    test "ROUND_MINUTE" do
      assert run(~s{ROUND_MINUTE(created_at) == NOW()}) == []
    end

    test "ROUND_HOUR" do
      assert run(~s{ROUND_HOUR(created_at) == NOW()}) == []
    end

    test "ROUND_DAY" do
      assert run(~s{ROUND_DAY(created_at) == NOW()}) == []
    end

    test "ROUND_WEEK" do
      assert run(~s{ROUND_WEEK(created_at) == NOW()}) == []
    end

    test "ROUND_MONTH" do
      assert run(~s{ROUND_MONTH(created_at) == NOW()}) == []
    end

    test "ROUND_QUARTER" do
      assert run(~s{ROUND_QUARTER(created_at) == NOW()}) == []
    end

    test "ROUND_YEAR" do
      assert run(~s{ROUND_YEAR(created_at) == NOW()}) == []
    end

    test "ROUND_DAY combined with NOW()" do
      assert run(~s{ROUND_DAY(created_at) == ROUND_DAY(NOW())}) == []
    end
  end

  # -- Interval functions (using created_at timestamp column) --

  describe "interval functions" do
    test "ADD_INTERVAL" do
      assert run(~s{ADD_INTERVAL(created_at, "1 day") >= NOW()}) == []
    end

    test "SUB_INTERVAL" do
      assert run(~s{SUB_INTERVAL(created_at, "2 hours") <= NOW()}) == []
    end

    test "nested with NOW()" do
      assert run(~s{created_at >= SUB_INTERVAL(NOW(), "7 days")}) == []
    end
  end

  # -- Logical operators --

  describe "logical operators" do
    test "AND" do
      assert run(~s{name == "alice" AND age == 30}) == []
    end

    test "OR" do
      assert run(~s{role == "admin" OR role == "mod"}) == []
    end

    test "grouped OR inside AND" do
      assert run(~s{(role == "admin" OR role == "mod") AND active == true}) == []
    end

    test "complex nested grouping" do
      assert run(~s{(name == "alice" AND age >= 18) OR (role == "admin" AND active == true)}) ==
               []
    end
  end

  # -- COALESCE --

  describe "coalesce" do
    test "coalesce with field and literal" do
      assert run(~s{COALESCE(name, "default") == "alice"}) == []
    end
  end

  # -- JSON paths --

  describe "JSON paths" do
    # Without type casting, #> returns jsonb which can't compare to varchar.
    # Use allowed_fields with type info for valid SQL.
    test "simple JSON path with type cast" do
      assert run(~s{metadata.key == "value"},
               allowed_fields: [metadata: :map, "metadata.key": :string]
             ) == []
    end

    test "nested JSON path with type cast" do
      assert run(~s{metadata.nested.key == "value"},
               allowed_fields: [metadata: :map, "metadata.nested.key": :string]
             ) == []
    end

    test "JSON path with integer type cast" do
      assert run(~s{metadata.count == 42},
               allowed_fields: [metadata: :map, "metadata.count": :integer]
             ) == []
    end
  end

  # -- Joins --

  describe "joins" do
    test "single-level join" do
      assert run(~s{author.name == "alice"}) == []
    end

    test "multi-level join" do
      assert run(~s{author.company.company_name == "Acme"}) == []
    end

    test "duplicate join dedup" do
      assert run(~s{author.name == "alice" AND author.email == "alice@example.com"}) == []
    end

    test "join with contains" do
      assert run(~s{author.name contains "ali"}) == []
    end
  end

  # -- Schemaless queries --

  @author_assoc {:assoc,
                 table: "authors",
                 owner_key: :author_id,
                 related_key: :id,
                 fields: [
                   name: :string,
                   email: :string,
                   company:
                     {:assoc,
                      table: "companies",
                      owner_key: :company_id,
                      related_key: :id,
                      fields: [company_name: :string]}
                 ]}

  describe "schemaless queries" do
    test "simple field access" do
      assert run_schemaless(~s{name == "alice"},
               allowed_fields: [name: :string, age: :integer]
             ) == []
    end

    test "single-level join via allowed_fields" do
      assert run_schemaless(~s{author.name == "alice"},
               allowed_fields: [name: :string, author: @author_assoc]
             ) == []
    end

    test "multi-level nested join" do
      assert run_schemaless(~s{author.company.company_name == "Acme"},
               allowed_fields: [name: :string, author: @author_assoc]
             ) == []
    end

    test "JSON path in schemaless mode" do
      assert run_schemaless(~s{metadata.key == "value"},
               allowed_fields: [metadata: :map, "metadata.key": :string]
             ) == []
    end
  end
end
