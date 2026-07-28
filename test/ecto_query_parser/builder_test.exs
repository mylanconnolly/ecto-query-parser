defmodule EctoQueryParser.BuilderTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias EctoQueryParser.Test.TestSchema

  defp build(query_string, opts \\ []) do
    EctoQueryParser.apply(TestSchema, query_string, opts)
  end

  defp inspect_query({:ok, query}) do
    inspect(query)
  end

  # Natural-language date transform used by the literal_transform tests.
  defp season_transform do
    fn
      :date, "last year" -> {:range, {~D[2025-01-01], ~D[2025-12-31]}}
      :date, "today" -> {:ok, ~D[2026-07-28]}
      _, _ -> :default
    end
  end

  describe "basic operators" do
    test "== with string" do
      assert {:ok, query} = build(~s{name == "alice"})
      assert inspect_query({:ok, query}) =~ "name"
    end

    test "== with integer" do
      assert {:ok, _query} = build("age == 42")
    end

    test "== with float" do
      assert {:ok, _query} = build("score == 3.14")
    end

    test "== with boolean" do
      assert {:ok, _query} = build("active == true")
    end

    test "!= operator" do
      assert {:ok, _query} = build(~s{status != "banned"})
    end

    test ">= operator" do
      assert {:ok, _query} = build("age >= 18")
    end

    test "<= operator" do
      assert {:ok, _query} = build("score <= 9.99")
    end

    test "> operator" do
      assert {:ok, query} = build("age > 18")
      assert inspect(query) =~ "age > ^18"
    end

    test "< operator" do
      assert {:ok, query} = build("score < 9.99")
      assert inspect(query) =~ "score < ^9.99"
    end

    test "> coerces literal against typed field" do
      assert {:ok, query} = build(~s{performed_on > "2026-05-20"})
      query_str = inspect(query)
      assert query_str =~ "type("
      assert query_str =~ ":date"
    end

    test "> works on association paths" do
      assert {:ok, query} = build(~s{author.hired_on > "2026-01-01"})
      query_str = inspect(query)
      assert query_str =~ "left_join"
      assert query_str =~ ":date"
    end
  end

  describe "NOT operator" do
    test "negates a comparison" do
      assert {:ok, query} = build(~s{NOT name == "alice"})
      assert inspect(query) =~ "not (" or inspect(query) =~ "not("
    end

    test "negates a grouped expression" do
      assert {:ok, query} = build(~s{NOT (role == "admin" OR role == "mod")})
      query_str = inspect(query)
      assert query_str =~ "not "
      assert query_str =~ " or "
    end

    test "NOT on plural association produces NOT EXISTS" do
      assert {:ok, query} =
               EctoQueryParser.apply(
                 EctoQueryParser.Test.Author,
                 ~s{NOT posts.name == "x"}
               )

      query_str = inspect(query)
      assert query_str =~ "not exists("
    end
  end

  describe "IS NULL / IS NOT NULL" do
    test "IS NULL on a plain field" do
      assert {:ok, query} = build("name IS NULL")
      assert inspect(query) =~ "is_nil"
    end

    test "IS NOT NULL on a plain field" do
      assert {:ok, query} = build("name IS NOT NULL")
      assert inspect(query) =~ "not is_nil"
    end

    test "IS NULL on an association path adds the join" do
      assert {:ok, query} = build("author.name IS NULL")
      query_str = inspect(query)
      assert query_str =~ "left_join"
      assert query_str =~ "is_nil"
    end

    test "IS NULL on a function expression" do
      assert {:ok, query} = build("TRIM(name) IS NULL")
      query_str = inspect(query)
      assert query_str =~ "TRIM"
      assert query_str =~ "is_nil"
    end

    test "IS NULL on a plural association goes inside EXISTS" do
      assert {:ok, query} =
               EctoQueryParser.apply(EctoQueryParser.Test.Author, "posts.name IS NULL")

      query_str = inspect(query)
      assert query_str =~ "exists("
      assert query_str =~ "is_nil"
    end

    test "IS NULL respects allowed_fields" do
      assert {:error, "field not allowed: role"} =
               build("role IS NULL", allowed_fields: [:name])
    end
  end

  describe "IN operator" do
    test "membership in an integer list" do
      assert {:ok, query} = build("age IN [1, 2, 3]")
      assert inspect(query) =~ "age in ^[1, 2, 3]"
    end

    test "membership in a string list" do
      assert {:ok, query} = build(~s{status in ["a", "b"]})
      assert inspect(query) =~ ~s|status in ^["a", "b"]|
    end

    test "coerces list elements against the field type" do
      assert {:ok, query} = build(~s{performed_on IN ["2026-01-01", "2026-01-02"]})
      query_str = inspect(query)
      assert query_str =~ "type("
      assert query_str =~ "{:array, :date}"
    end

    test "no coercion when element types already match" do
      assert {:ok, query} = build("age IN [1, 2]")
      refute inspect(query) =~ "type("
    end

    test "works on association paths" do
      assert {:ok, query} = build(~s{author.name IN ["alice", "bob"]})
      query_str = inspect(query)
      assert query_str =~ "left_join"
      assert query_str =~ " in ^"
    end

    test "non-list value errors" do
      assert {:error, msg} = build("age IN 5")
      assert msg =~ "IN operator requires a list value"
    end
  end

  describe "BETWEEN operator" do
    test "expands to >= AND <=" do
      assert {:ok, query} = build("age BETWEEN 1 AND 10")
      query_str = inspect(query)
      assert query_str =~ "age >= ^1"
      assert query_str =~ "age <= ^10"
    end

    test "coerces both bounds against the field type" do
      assert {:ok, query} = build(~s{performed_on BETWEEN "2026-01-01" AND "2026-02-01"})
      query_str = inspect(query)
      assert occurrences(query_str, "type(") == 2
      assert query_str =~ ":date"
    end

    test "works on association paths" do
      assert {:ok, query} = build(~s{author.hired_on BETWEEN "2026-01-01" AND "2026-02-01"})
      query_str = inspect(query)
      assert query_str =~ "left_join"
      assert query_str =~ ">="
      assert query_str =~ "<="
    end

    test "works inside boolean expressions" do
      assert {:ok, query} = build(~s{(age BETWEEN 18 AND 65) AND active == true})
      query_str = inspect(query)
      assert query_str =~ ">= ^18"
      assert query_str =~ "<= ^65"
    end

    test "BETWEEN on a plural association goes inside EXISTS" do
      assert {:ok, query} =
               EctoQueryParser.apply(EctoQueryParser.Test.Author, "posts.age BETWEEN 1 AND 5")

      query_str = inspect(query)
      assert query_str =~ "exists("
      assert query_str =~ ">= ^1"
      assert query_str =~ "<= ^5"
    end

    test "respects allowed_fields" do
      assert {:error, "field not allowed: age"} =
               build("age BETWEEN 1 AND 10", allowed_fields: [:name])
    end
  end

  describe "text operators" do
    test "contains" do
      assert {:ok, _query} = build(~s{name contains "alice"})
    end

    test "contains escapes special LIKE characters" do
      assert {:ok, _query} = build(~s{name contains "100%"})
    end

    test "contains with identifier" do
      assert {:ok, query} = build(~s{name contains role})
      assert %Ecto.Query{} = query
      assert inspect(query) =~ "'%' || ? || '%'"
    end

    test "like" do
      assert {:ok, _query} = build(~s{name like "%alice%"})
    end

    test "ilike" do
      assert {:ok, _query} = build(~s{name ilike "%ALICE%"})
    end

    test "search with single word" do
      assert {:ok, _query} = build(~s{body search "elixir"})
    end

    test "search with multiple words" do
      assert {:ok, _query} = build(~s{body search "elixir programming"})
    end

    test "search with empty string returns true" do
      assert {:ok, _query} = build(~s{body search ""})
    end
  end

  describe "includes operator" do
    test "includes with string value" do
      assert {:ok, _query} = build(~s{tags includes "elixir"})
    end

    test "includes with integer value" do
      assert {:ok, _query} = build("age includes 42")
    end
  end

  describe "AND/OR with grouping" do
    test "simple AND" do
      assert {:ok, _query} = build(~s{name == "alice" AND age == 30})
    end

    test "simple OR" do
      assert {:ok, _query} = build(~s{role == "admin" OR role == "mod"})
    end

    test "AND and OR precedence" do
      assert {:ok, _query} = build(~s{name == "alice" OR age >= 18 AND active == true})
    end

    test "grouped OR inside AND" do
      assert {:ok, _query} = build(~s{(role == "admin" OR role == "mod") AND active == true})
    end

    test "complex nested grouping" do
      assert {:ok, _query} =
               build(~s{(name == "alice" AND age >= 18) OR (role == "admin" AND active == true)})
    end
  end

  describe "functions" do
    test "to_upper / upper" do
      assert {:ok, _query} = build(~s{TO_UPPER(name) == "ALICE"})
    end

    test "to_lower / lower" do
      assert {:ok, _query} = build(~s{LOWER(name) == "alice"})
    end

    test "trim" do
      assert {:ok, _query} = build(~s{TRIM(name) == "alice"})
    end

    test "coalesce" do
      assert {:ok, _query} = build(~s{coalesce(name, "default") == "alice"})
    end

    test "nested functions" do
      assert {:ok, _query} = build(~s{TO_UPPER(TRIM(name)) == "ALICE"})
    end

    test "concat with two args" do
      assert {:ok, _query} = build(~s{concat(name, role) == "aliceadmin"})
    end

    test "replace" do
      assert {:ok, query} = build(~s{REPLACE(name, "alice", "bob") == "bob"})
      assert inspect(query) =~ "REPLACE"
    end

    test "abs" do
      assert {:ok, query} = build(~s{ABS(age) >= 5})
      assert inspect(query) =~ "ABS"
    end

    test "floor" do
      assert {:ok, query} = build(~s{FLOOR(score) == 3})
      assert inspect(query) =~ "FLOOR"
    end

    test "ceil" do
      assert {:ok, query} = build(~s{CEIL(score) == 4})
      assert inspect(query) =~ "CEIL"
    end

    test "now" do
      assert {:ok, query} = build(~s{NOW() >= NOW()})
      assert inspect(query) =~ "NOW()"
    end

    test "unknown function returns error" do
      assert {:error, "unknown function: bogus"} = build(~s{bogus(name) == "x"})
    end
  end

  describe "date truncation functions" do
    test "round_second" do
      assert {:ok, query} = build(~s{ROUND_SECOND(name) == "x"})
      query_str = inspect(query)
      assert query_str =~ "DATE_TRUNC"
      assert query_str =~ "second"
    end

    test "round_minute" do
      assert {:ok, query} = build(~s{ROUND_MINUTE(name) == "x"})
      assert inspect(query) =~ "minute"
    end

    test "round_hour" do
      assert {:ok, query} = build(~s{ROUND_HOUR(name) == "x"})
      assert inspect(query) =~ "hour"
    end

    test "round_day" do
      assert {:ok, query} = build(~s{ROUND_DAY(name) == "x"})
      assert inspect(query) =~ "day"
    end

    test "round_week" do
      assert {:ok, query} = build(~s{ROUND_WEEK(name) == "x"})
      assert inspect(query) =~ "week"
    end

    test "round_month" do
      assert {:ok, query} = build(~s{ROUND_MONTH(name) == "x"})
      assert inspect(query) =~ "month"
    end

    test "round_quarter" do
      assert {:ok, query} = build(~s{ROUND_QUARTER(name) == "x"})
      assert inspect(query) =~ "quarter"
    end

    test "round_year" do
      assert {:ok, query} = build(~s{ROUND_YEAR(name) == "x"})
      assert inspect(query) =~ "year"
    end

    test "case insensitive" do
      assert {:ok, query} = build(~s{round_day(name) == "x"})
      assert inspect(query) =~ "DATE_TRUNC"
    end

    test "combined with NOW()" do
      assert {:ok, query} = build(~s{ROUND_DAY(name) == ROUND_DAY(NOW())})
      query_str = inspect(query)
      assert query_str =~ "DATE_TRUNC"
      assert query_str =~ "NOW()"
    end
  end

  describe "interval functions" do
    test "add_interval" do
      assert {:ok, query} = build(~s{ADD_INTERVAL(name, "1 day") >= NOW()})
      query_str = inspect(query)
      assert query_str =~ "::interval"
      assert query_str =~ "+"
    end

    test "sub_interval" do
      assert {:ok, query} = build(~s{SUB_INTERVAL(name, "2 hours") <= NOW()})
      query_str = inspect(query)
      assert query_str =~ "::interval"
      assert query_str =~ "-"
    end

    test "case insensitive" do
      assert {:ok, query} = build(~s{add_interval(name, "30 minutes") >= NOW()})
      assert inspect(query) =~ "::interval"
    end

    test "nested with NOW()" do
      assert {:ok, query} = build(~s{name >= SUB_INTERVAL(NOW(), "7 days")})
      query_str = inspect(query)
      assert query_str =~ "NOW()"
      assert query_str =~ "::interval"
    end
  end

  describe "allowed_fields option" do
    test "allowed field succeeds" do
      assert {:ok, _query} = build(~s{name == "alice"}, allowed_fields: [:name, :age])
    end

    test "disallowed field errors" do
      assert {:error, "field not allowed: role"} =
               build(~s{role == "admin"}, allowed_fields: [:name, :age])
    end

    test "without option, all fields allowed" do
      assert {:ok, _query} = build(~s{role == "admin"})
    end
  end

  describe "error cases" do
    test "parse failures propagate as ParseError structs through apply/3" do
      assert {:error, %EctoQueryParser.ParseError{}} = build("")
      assert {:error, %EctoQueryParser.ParseError{} = err} = build(~s{name == "alice" AND})
      assert err.line == 1
      assert Exception.message(err) =~ "column"
    end

    test "builder errors keep the binary error shape" do
      assert {:error, reason} = build(~s{nonexistent_field_xyz == "x"})
      assert is_binary(reason)
    end

    test "unknown field" do
      assert {:error, "unknown field: nonexistent_field_xyz"} =
               build(~s{nonexistent_field_xyz == "x"})
    end

    test "contains requires string or identifier" do
      assert {:error, msg} = build(~s{name contains 42})
      assert msg =~ "contains operator requires a string or identifier value"
    end

    test "search requires string" do
      assert {:error, msg} = build(~s{body search 42})
      assert msg =~ "search operator requires a string value"
    end
  end

  describe "apply/3 integration" do
    test "returns Ecto query struct" do
      assert {:ok, query} = EctoQueryParser.apply(TestSchema, ~s{name == "alice"})
      assert %Ecto.Query{} = query
    end

    test "composes with existing query" do
      base = from(t in TestSchema, select: t.name)
      assert {:ok, query} = EctoQueryParser.apply(base, ~s{active == true})
      assert %Ecto.Query{} = query
    end
  end

  describe "dotted identifiers (join support)" do
    test "single-level dotted identifier adds left join" do
      assert {:ok, query} = build(~s{author.name == "alice"})
      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ "left_join"
      assert query_str =~ "author"
    end

    test "duplicate joins are deduplicated" do
      assert {:ok, query} =
               build(~s{author.name == "alice" AND author.email == "alice@example.com"})

      assert %Ecto.Query{} = query
      # Only one join should exist
      assert length(query.joins) == 1
    end

    test "multi-level nesting creates multiple joins" do
      assert {:ok, query} = build(~s{author.company.company_name == "Acme"})
      assert %Ecto.Query{} = query
      # Two joins: author, then author__company
      assert length(query.joins) == 2
    end

    test "mixing dotted and plain identifiers" do
      assert {:ok, query} = build(~s{name == "alice" AND author.name == "bob"})
      assert %Ecto.Query{} = query
      assert length(query.joins) == 1
    end

    test "dotted identifier with allowed_fields" do
      assert {:ok, _query} =
               build(~s{author.name == "alice"}, allowed_fields: [:name, :"author.name"])
    end

    test "dotted identifier rejected by allowed_fields" do
      assert {:error, "field not allowed: author.name"} =
               build(~s{author.name == "alice"}, allowed_fields: [:name])
    end

    test "unknown association returns error" do
      assert {:error, msg} = build(~s{nonexistent.name == "x"})
      assert msg =~ "unknown association"
    end

    test "works with contains operator" do
      assert {:ok, query} = build(~s{author.name contains "ali"})
      assert %Ecto.Query{} = query
      assert length(query.joins) == 1
    end

    test "composes with existing query using dotted identifier" do
      base = from(t in TestSchema, select: t.name)
      assert {:ok, query} = EctoQueryParser.apply(base, ~s{author.name == "alice"})
      assert %Ecto.Query{} = query
      assert length(query.joins) == 1
    end
  end

  describe "JSONB column access" do
    test "simple JSON path produces no joins" do
      assert {:ok, query} = build(~s{metadata.key == "value"})
      assert %Ecto.Query{} = query
      assert query.joins == []
      assert inspect(query) =~ ~s|metadata["key"]|
    end

    test "nested JSON path" do
      assert {:ok, query} = build(~s{metadata.nested.key == "value"})
      assert %Ecto.Query{} = query
      assert query.joins == []
      assert inspect(query) =~ ~s|metadata["nested"]["key"]|
    end

    test "JSON path combined with regular field via AND" do
      assert {:ok, query} = build(~s{name == "alice" AND metadata.key == "value"})
      assert %Ecto.Query{} = query
      assert query.joins == []
    end

    test "JSON path combined with association via AND" do
      assert {:ok, query} =
               build(~s{author.name == "bob" AND metadata.key == "value"})

      assert %Ecto.Query{} = query
      # One join for author, none for metadata
      assert length(query.joins) == 1
    end

    test "contains on JSON path" do
      assert {:ok, query} = build(~s{metadata.name contains "ali"})
      assert %Ecto.Query{} = query
      assert query.joins == []
    end

    test "function wrapping JSON path" do
      assert {:ok, query} = build(~s{TO_UPPER(metadata.name) == "ALICE"})
      assert %Ecto.Query{} = query
      assert query.joins == []
    end

    test "association path still uses joins (not treated as JSON)" do
      assert {:ok, query} = build(~s{author.name == "alice"})
      assert %Ecto.Query{} = query
      assert length(query.joins) == 1
    end

    test "JSON path without allowed_fields uses schema introspection, no type cast" do
      assert {:ok, query} = build(~s{metadata.key == "value"})
      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ ~s|metadata["key"]|
      refute query_str =~ "type("
    end
  end

  describe "schemaless query support" do
    defp schemaless_build(query_string, opts \\ []) do
      import Ecto.Query, only: [from: 1]
      EctoQueryParser.apply(from("test_items"), query_string, opts)
    end

    @author_assoc {:assoc,
                   table: "users",
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

    test "simple field access without schema" do
      assert {:ok, query} =
               schemaless_build(~s{name == "alice"},
                 allowed_fields: [name: :string, age: :integer]
               )

      assert %Ecto.Query{} = query
      assert query.joins == []
    end

    test "single-level join via allowed_fields" do
      assert {:ok, query} =
               schemaless_build(~s{author.name == "alice"},
                 allowed_fields: [name: :string, author: @author_assoc]
               )

      assert %Ecto.Query{} = query
      assert length(query.joins) == 1
      query_str = inspect(query)
      assert query_str =~ "left_join"
      assert query_str =~ "users"
    end

    test "multi-level nested join creates multiple joins" do
      assert {:ok, query} =
               schemaless_build(~s{author.company.company_name == "Acme"},
                 allowed_fields: [name: :string, author: @author_assoc]
               )

      assert %Ecto.Query{} = query
      assert length(query.joins) == 2
    end

    test "JSON path in schemaless mode" do
      assert {:ok, query} =
               schemaless_build(~s{metadata.key == "value"},
                 allowed_fields: [metadata: :map, "metadata.key": :string]
               )

      assert %Ecto.Query{} = query
      assert query.joins == []
      query_str = inspect(query)
      assert query_str =~ ~s|metadata["key"]|
      assert query_str =~ "type("
    end

    test "duplicate join dedup" do
      assert {:ok, query} =
               schemaless_build(
                 ~s{author.name == "alice" AND author.email == "alice@example.com"},
                 allowed_fields: [name: :string, author: @author_assoc]
               )

      assert %Ecto.Query{} = query
      assert length(query.joins) == 1
    end

    test "rejected field in schemaless mode" do
      assert {:error, "field not allowed: role"} =
               schemaless_build(~s{role == "admin"}, allowed_fields: [name: :string])
    end

    test "mixed join + JSON + plain field in one query" do
      assert {:ok, query} =
               schemaless_build(
                 ~s{name == "alice" AND author.name == "bob" AND metadata.key == "val"},
                 allowed_fields: [
                   name: :string,
                   author: @author_assoc,
                   metadata: :map,
                   "metadata.key": :string
                 ]
               )

      assert %Ecto.Query{} = query
      assert length(query.joins) == 1
    end

    test "nested-only validation (no direct dotted key needed)" do
      # No :"author.name" key required — validated through assoc's :fields
      assert {:ok, _query} =
               schemaless_build(~s{author.name == "alice"},
                 allowed_fields: [author: @author_assoc]
               )
    end

    test "dotted identifier without allowed_fields errors clearly" do
      assert {:error, msg} = schemaless_build(~s{author.name == "alice"})
      assert msg =~ "cannot resolve dotted identifier"
      assert msg =~ "no schema available"
    end

    test "dotted identifier on non-assoc non-map field errors" do
      assert {:error, msg} =
               schemaless_build(~s{name.foo == "x"},
                 allowed_fields: [name: :string, "name.foo": :string]
               )

      assert msg =~ "not an association or map field"
    end

    test "schema-based resolution still works unchanged (backward compat)" do
      assert {:ok, query} = build(~s{author.name == "alice"})
      assert %Ecto.Query{} = query
      assert length(query.joins) == 1
    end
  end

  describe "literal type coercion" do
    test "schema-typed date field with string literal wraps in type/2" do
      assert {:ok, query} = build(~s{performed_on >= "2026-05-20"})
      query_str = inspect(query)
      assert query_str =~ "type("
      assert query_str =~ ":date"
    end

    test "schema-typed date field with == operator" do
      assert {:ok, query} = build(~s{performed_on == "2026-05-20"})
      assert inspect(query) =~ "type("
    end

    test "schema-typed utc_datetime with ISO8601 string" do
      assert {:ok, query} = build(~s{created_at >= "2026-05-20T10:00:00Z"})
      query_str = inspect(query)
      assert query_str =~ "type("
      assert query_str =~ ":utc_datetime"
    end

    test "schema-typed decimal field coerces integer literal" do
      assert {:ok, query} = build(~s{balance >= 100})
      query_str = inspect(query)
      assert query_str =~ "type("
      assert query_str =~ ":decimal"
    end

    test "reversed operand order still coerces (literal on the left)" do
      assert {:ok, query} = build(~s{"2026-05-20" <= performed_on})
      query_str = inspect(query)
      assert query_str =~ "type("
      assert query_str =~ ":date"
    end

    test "production-style mixed query" do
      assert {:ok, query} = build(~s{status == "n" AND performed_on >= "2026-05-20"})
      query_str = inspect(query)
      assert query_str =~ "type("
      assert query_str =~ ":date"
      # status is :string, no coercion needed there
      assert query_str =~ "status"
    end

    test "string field with string literal: no type wrapping" do
      assert {:ok, query} = build(~s{name == "alice"})
      refute inspect(query) =~ "type("
    end

    test "integer field with integer literal: no type wrapping" do
      assert {:ok, query} = build(~s{age == 42})
      refute inspect(query) =~ "type("
    end

    test "float field with float literal: no type wrapping" do
      assert {:ok, query} = build(~s{score == 3.14})
      refute inspect(query) =~ "type("
    end

    test "boolean field with boolean literal: no type wrapping" do
      assert {:ok, query} = build(~s{active == true})
      refute inspect(query) =~ "type("
    end

    test "field-vs-field comparison: no coercion" do
      assert {:ok, query} = build(~s{created_at >= created_at})
      refute inspect(query) =~ "type("
    end

    test "dotted association: leaf field type drives coercion" do
      assert {:ok, query} = build(~s{author.hired_on >= "2026-01-01"})
      query_str = inspect(query)
      assert query_str =~ "type("
      assert query_str =~ ":date"
      assert query_str =~ "left_join"
    end

    test "schemaless mode with keyword allowed_fields coerces date" do
      import Ecto.Query, only: [from: 1]

      assert {:ok, query} =
               EctoQueryParser.apply(
                 from("test_items"),
                 ~s{performed_on >= "2026-05-20"},
                 allowed_fields: [performed_on: :date, status: :string]
               )

      query_str = inspect(query)
      assert query_str =~ "type("
      assert query_str =~ ":date"
    end

    test "schemaless mode: nested assoc coerces leaf date type" do
      assoc =
        {:assoc,
         table: "authors",
         owner_key: :author_id,
         related_key: :id,
         fields: [name: :string, hired_on: :date]}

      import Ecto.Query, only: [from: 1]

      assert {:ok, query} =
               EctoQueryParser.apply(
                 from("test_items"),
                 ~s{author.hired_on >= "2026-01-01"},
                 allowed_fields: [author: assoc]
               )

      query_str = inspect(query)
      assert query_str =~ "type("
      assert query_str =~ ":date"
    end

    test "JSON sub-path with date type coerces literal" do
      assert {:ok, query} =
               build(~s{metadata.start >= "2026-05-20"},
                 allowed_fields: [metadata: :map, "metadata.start": :date]
               )

      query_str = inspect(query)
      # type appears twice: once wrapping json_extract_path, once wrapping the literal
      assert query_str =~ ~s|metadata["start"]|
      assert query_str =~ ":date"
    end

    test "includes coerces element for typed array (schemaless)" do
      import Ecto.Query, only: [from: 1]

      assert {:ok, query} =
               EctoQueryParser.apply(
                 from("test_items"),
                 ~s{event_dates includes "2026-05-20"},
                 allowed_fields: [event_dates: {:array, :date}]
               )

      query_str = inspect(query)
      assert query_str =~ "type("
      assert query_str =~ ":date"
    end

    test "includes on {:array, :string} field: no type wrapping" do
      assert {:ok, query} = build(~s{tags includes "elixir"})
      refute inspect(query) =~ "type("
    end

    test "unknown field still errors before coercion" do
      assert {:error, "unknown field: nonexistent_field_xyz"} =
               build(~s{nonexistent_field_xyz >= "2026-05-20"})
    end

    test "coercion respects allowed_fields override of schema type" do
      # If user explicitly types a field via allowed_fields, that wins over schema
      assert {:ok, query} =
               build(~s{performed_on >= "2026-05-20"},
                 allowed_fields: [performed_on: :date]
               )

      assert inspect(query) =~ "type("
    end
  end

  describe "keyword allowed_fields" do
    test "keyword format allows permitted fields" do
      assert {:ok, _query} =
               build(~s{name == "alice"}, allowed_fields: [name: :string, age: :integer])
    end

    test "keyword format rejects disallowed fields" do
      assert {:error, "field not allowed: role"} =
               build(~s{role == "admin"}, allowed_fields: [name: :string, age: :integer])
    end

    test "keyword format with typed JSON sub-path applies type cast" do
      assert {:ok, query} =
               build(~s{metadata.key == "value"},
                 allowed_fields: [metadata: :map, "metadata.key": :string]
               )

      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ ~s|metadata["key"]|
      assert query_str =~ "type("
    end

    test "keyword format with integer type for JSON sub-path" do
      assert {:ok, query} =
               build(~s{metadata.count == 42},
                 allowed_fields: [metadata: :map, "metadata.count": :integer]
               )

      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ ~s|metadata["count"]|
      assert query_str =~ "type("
    end

    test "keyword format for JSON path without sub-path type uses no type cast" do
      assert {:ok, query} =
               build(~s{metadata.key == "value"},
                 allowed_fields: [metadata: :map, "metadata.key": nil]
               )

      assert %Ecto.Query{} = query
      query_str = inspect(query)
      assert query_str =~ ~s|metadata["key"]|
      refute query_str =~ "type("
    end

    test "keyword format rejects disallowed JSON sub-path" do
      assert {:error, "field not allowed: metadata.secret"} =
               build(~s{metadata.secret == "x"},
                 allowed_fields: [metadata: :map, "metadata.key": :string]
               )
    end

    test "plain list allowed_fields still works (backward compat)" do
      assert {:ok, _query} = build(~s{name == "alice"}, allowed_fields: [:name, :age])

      assert {:error, "field not allowed: role"} =
               build(~s{role == "admin"}, allowed_fields: [:name, :age])
    end

    test "plain list allowed_fields with dotted JSON path" do
      assert {:ok, query} =
               build(~s{metadata.key == "value"}, allowed_fields: [:name, :"metadata.key"])

      assert %Ecto.Query{} = query
      assert query.joins == []
    end
  end

  describe "plural associations (has_many, many_to_many)" do
    import Ecto.Query, only: [from: 1, from: 2]

    @posts_assoc {:has_many,
                  table: "test_items",
                  owner_key: :id,
                  related_key: :author_id,
                  fields: [body: :string, status: :string]}

    @likes_assoc {:has_many,
                  table: "likes",
                  owner_key: :id,
                  related_key: :post_id,
                  fields: [user_id: :integer]}

    @tags_assoc {:many_to_many,
                 table: "tags",
                 join_through: "post_tags",
                 join_owner_key: :post_id,
                 join_related_key: :tag_id,
                 owner_key: :id,
                 related_key: :id,
                 fields: [name: :string]}

    @comments_with_author {:has_many,
                           table: "comments",
                           owner_key: :id,
                           related_key: :post_id,
                           fields: [
                             body: :string,
                             status: :string,
                             author:
                               {:belongs_to,
                                table: "authors",
                                owner_key: :author_id,
                                related_key: :id,
                                fields: [name: :string]}
                           ]}

    defp plural_build(query_string, opts) do
      EctoQueryParser.apply(from("test_items"), query_string, opts)
    end

    # 1. :belongs_to alias of :assoc still produces LEFT JOIN
    test "belongs_to tag is an alias of :assoc (LEFT JOIN unchanged)" do
      author =
        {:belongs_to,
         table: "authors", owner_key: :author_id, related_key: :id, fields: [name: :string]}

      assert {:ok, query} =
               plural_build(~s{author.name == "alice"}, allowed_fields: [author: author])

      query_str = inspect(query)
      assert query_str =~ "left_join"
      assert query_str =~ "authors"
      refute query_str =~ "exists("
    end

    # 2. schemaless has_many produces EXISTS
    test "has_many produces EXISTS subquery, no LEFT JOIN" do
      assert {:ok, query} =
               plural_build(~s{posts.body contains "ship"},
                 allowed_fields: [posts: @posts_assoc]
               )

      query_str = inspect(query)
      assert query_str =~ "exists("
      assert query_str =~ "test_items"
      assert query.joins == []
    end

    # 3. AND on same plural alias collapses into one EXISTS
    test "AND on same plural alias collapses to one EXISTS with combined predicates" do
      assert {:ok, query} =
               plural_build(
                 ~s{posts.status == "live" AND posts.body contains "ship"},
                 allowed_fields: [posts: @posts_assoc]
               )

      query_str = inspect(query)
      # Exactly one EXISTS clause for the plural binding
      assert occurrences(query_str, "exists(") == 1
      assert query_str =~ "live"
      assert query_str =~ "ship"
    end

    # 4. OR on same plural alias collapses into one EXISTS with OR inside
    test "OR on same plural alias collapses to one EXISTS with OR-ed predicates" do
      assert {:ok, query} =
               plural_build(
                 ~s{posts.status == "live" OR posts.body contains "ship"},
                 allowed_fields: [posts: @posts_assoc]
               )

      query_str = inspect(query)
      assert occurrences(query_str, "exists(") == 1
      assert query_str =~ " or "
    end

    # 5. Two distinct plural aliases → two EXISTS clauses
    test "two distinct plural aliases produce two EXISTS clauses" do
      assert {:ok, query} =
               plural_build(
                 ~s{posts.body contains "x" AND likes.user_id == 42},
                 allowed_fields: [posts: @posts_assoc, likes: @likes_assoc]
               )

      query_str = inspect(query)
      assert occurrences(query_str, "exists(") == 2
    end

    # 6. Mixed singular + plural: LEFT JOIN for singular, EXISTS for plural
    test "singular + plural mix yields one LEFT JOIN and one EXISTS" do
      author =
        {:belongs_to,
         table: "authors", owner_key: :author_id, related_key: :id, fields: [name: :string]}

      assert {:ok, query} =
               plural_build(
                 ~s{author.name == "alice" AND posts.body contains "ship"},
                 allowed_fields: [author: author, posts: @posts_assoc]
               )

      query_str = inspect(query)
      assert query_str =~ "left_join"
      assert query_str =~ "exists("
      assert length(query.joins) == 1
    end

    # 7. schemaless many_to_many produces EXISTS through join table
    test "many_to_many produces EXISTS through join table" do
      assert {:ok, query} =
               plural_build(~s{tags.name == "elixir"},
                 allowed_fields: [tags: @tags_assoc]
               )

      query_str = inspect(query)
      assert query_str =~ "exists("
      assert query_str =~ "post_tags"
      assert query_str =~ "tags"
      # inner join renders as `join:` in Ecto's inspect output (no qualifier prefix)
      assert query_str =~ ~r/join:\s+\w+ in "post_tags"/
    end

    # 8. nested has_many → belongs_to: EXISTS containing a LEFT JOIN
    test "nested has_many → belongs_to: EXISTS contains a LEFT JOIN" do
      assert {:ok, query} =
               plural_build(~s{comments.author.name == "alice"},
                 allowed_fields: [comments: @comments_with_author]
               )

      query_str = inspect(query)
      assert query_str =~ "exists("
      # The inner LEFT JOIN renders as part of the subquery
      assert query_str =~ "left_join"
    end

    # 9. :prefix on belongs_to surfaces in LEFT JOIN
    test ":prefix on belongs_to uses {prefix, table} in the LEFT JOIN" do
      author =
        {:belongs_to,
         table: "authors",
         prefix: "tenant_42",
         owner_key: :author_id,
         related_key: :id,
         fields: [name: :string]}

      assert {:ok, query} =
               plural_build(~s{author.name == "alice"}, allowed_fields: [author: author])

      assert inspect(query) =~ "tenant_42"
    end

    # 10. :prefix on has_many surfaces in EXISTS subquery's FROM
    test ":prefix on has_many uses {prefix, table} in EXISTS source" do
      posts =
        {:has_many,
         table: "test_items",
         prefix: "tenant_42",
         owner_key: :id,
         related_key: :author_id,
         fields: [body: :string]}

      assert {:ok, query} =
               plural_build(~s{posts.body contains "x"}, allowed_fields: [posts: posts])

      assert inspect(query) =~ "tenant_42"
    end

    # 10b. :join_prefix on many_to_many: must not blow up on {string, string}
    # tuple interpolation, and must produce a plain inner join (not a subquery
    # join) on the prefixed join table.
    test ":join_prefix on many_to_many uses prefix option on the inner join" do
      tags =
        {:many_to_many,
         table: "tags",
         prefix: "public",
         join_through: "post_tags",
         join_prefix: "public",
         join_owner_key: :post_id,
         join_related_key: :tag_id,
         owner_key: :id,
         related_key: :id,
         fields: [name: :string]}

      assert {:ok, query} =
               plural_build(~s{tags.name == "elixir"}, allowed_fields: [tags: tags])

      query_str = inspect(query)
      # Plain inner join — not a subquery join — and prefix applied
      assert query_str =~ ~r/join:\s+\w+ in "post_tags"/
      refute query_str =~ ~r/join:\s+\w+ in subquery/
      assert query_str =~ "public"
    end

    # 11. unknown field on plural surfaces as an error
    test "unknown field on plural alias errors via inner validation" do
      assert {:error, msg} =
               plural_build(~s{posts.bogus == 1}, allowed_fields: [posts: @posts_assoc])

      assert msg =~ "bogus"
    end

    # 12. schema-mode has_many auto-detect → EXISTS
    test "schema-mode has_many is auto-detected and produces EXISTS" do
      assert {:ok, query} =
               EctoQueryParser.apply(
                 EctoQueryParser.Test.Author,
                 ~s{posts.name == "alice"}
               )

      query_str = inspect(query)
      assert query_str =~ "exists("
      # No LEFT JOIN to posts at the outer level
      refute Enum.any?(query.joins, fn join ->
               match?(%{as: as} when as in [:posts], join)
             end)
    end

    # 13. schema-mode many_to_many auto-detect → EXISTS through join table
    test "schema-mode many_to_many is auto-detected and produces EXISTS with join" do
      assert {:ok, query} =
               EctoQueryParser.apply(
                 EctoQueryParser.Test.TestSchema,
                 ~s{tag_list.name == "elixir"}
               )

      query_str = inspect(query)
      assert query_str =~ "exists("
      assert query_str =~ ~r/join:\s+\w+ in "post_tags"/
      assert query_str =~ "post_tags"
    end

    # 14. Nested boolean tree with mixed plural references
    test "nested boolean tree with mixed plurals keeps EXISTS clauses correctly grouped" do
      assert {:ok, query} =
               plural_build(
                 ~s{posts.status == "live" AND (likes.user_id == 1 OR posts.body contains "x")},
                 allowed_fields: [posts: @posts_assoc, likes: @likes_assoc]
               )

      query_str = inspect(query)
      # Outer AND has two items; inner OR has two items. Each plural ref under
      # different boolean nodes stays in its own EXISTS — three EXISTS total.
      assert occurrences(query_str, "exists(") == 3
    end

    # 15. v1 restriction: plural can only appear as the first segment
    test "plural at non-leading position errors with helpful message" do
      author_with_posts =
        {:belongs_to,
         table: "authors",
         owner_key: :author_id,
         related_key: :id,
         fields: [
           name: :string,
           posts:
             {:has_many,
              table: "test_items",
              owner_key: :id,
              related_key: :author_id,
              fields: [body: :string]}
         ]}

      assert {:error, msg} =
               plural_build(~s{author.posts.body contains "x"},
                 allowed_fields: [author: author_with_posts]
               )

      assert msg =~ "posts"
      assert msg =~ "first segment"
    end

    # 16. User-supplied source binding flows through to parent_as
    test "user-named source binding is used in EXISTS parent_as" do
      assert {:ok, query} =
               EctoQueryParser.apply(
                 from(p in "test_items", as: :my_post),
                 ~s{posts.body contains "x"},
                 allowed_fields: [posts: @posts_assoc]
               )

      assert query.from.as == :my_post
      assert inspect(query) =~ "parent_as(:my_post)"
    end

    test "default source binding is :__eqp_source when user did not name it" do
      assert {:ok, query} =
               plural_build(~s{posts.body contains "x"},
                 allowed_fields: [posts: @posts_assoc]
               )

      assert query.from.as == :__eqp_source
      assert inspect(query) =~ "parent_as(:__eqp_source)"
    end
  end

  describe "parameters (params option)" do
    test "string param binds like an inline literal" do
      assert {:ok, query} = build("name == {{n}}", params: %{"n" => "alice"})
      query_str = inspect(query)
      assert query_str =~ ~s|name == ^"alice"|
      refute query_str =~ "type("
    end

    test "integer param binds without coercion against integer field" do
      assert {:ok, query} = build("age >= {{min}}", params: %{"min" => 21})
      query_str = inspect(query)
      assert query_str =~ "age >= ^21"
      refute query_str =~ "type("
    end

    test "string param coerces against a typed field (type/2 wrap)" do
      assert {:ok, query} = build("performed_on >= {{start}}", params: %{"start" => "2026-05-20"})
      query_str = inspect(query)
      assert query_str =~ "type("
      assert query_str =~ ":date"
    end

    test "Date struct param is pinned and cast against the date field" do
      assert {:ok, query} = build("performed_on == {{d}}", params: %{"d" => ~D[2026-05-20]})
      query_str = inspect(query)
      assert query_str =~ "~D[2026-05-20]"
      assert query_str =~ ":date"
    end

    test "param works on the left side of a comparison" do
      assert {:ok, query} = build("{{start}} <= performed_on", params: %{"start" => "2026-05-20"})
      query_str = inspect(query)
      assert query_str =~ "type("
      assert query_str =~ ":date"
    end

    test "param in an IN list coerces with the other elements" do
      assert {:ok, query} =
               build(~s(performed_on IN ["2026-01-01", {{d}}]), params: %{"d" => "2026-01-02"})

      query_str = inspect(query)
      assert query_str =~ "{:array, :date}"
      assert query_str =~ "2026-01-02"
    end

    test "list param for IN binds the whole list" do
      assert {:ok, query} = build("age IN [{{a}}, {{b}}]", params: %{"a" => 1, "b" => 2})
      assert inspect(query) =~ "age in ^[1, 2]"
    end

    test "param as BETWEEN bounds" do
      assert {:ok, query} =
               build("performed_on BETWEEN {{lo}} AND {{hi}}",
                 params: %{"lo" => "2026-01-01", "hi" => "2026-02-01"}
               )

      query_str = inspect(query)
      assert query_str =~ ">="
      assert query_str =~ "<="
      assert occurrences(query_str, "type(") == 2
    end

    test "string param works with contains (pattern is escaped)" do
      assert {:ok, query} = build("name contains {{q}}", params: %{"q" => "al%ice"})
      assert inspect(query) =~ ~s|%al\\\\%ice%|
    end

    test "non-string param with contains errors like an inline literal" do
      assert {:error, msg} = build("name contains {{q}}", params: %{"q" => 42})
      assert msg =~ "contains operator requires a string or identifier value"
    end

    test "param on an association path coerces to the leaf type" do
      assert {:ok, query} =
               build("author.hired_on >= {{start}}", params: %{"start" => "2026-01-01"})

      query_str = inspect(query)
      assert query_str =~ "left_join"
      assert query_str =~ ":date"
    end

    test "param inside an EXISTS predicate (plural association)" do
      assert {:ok, query} =
               EctoQueryParser.apply(
                 EctoQueryParser.Test.Author,
                 "posts.name == {{n}}",
                 params: %{"n" => "hello"}
               )

      query_str = inspect(query)
      assert query_str =~ "exists("
      assert query_str =~ ~s|^"hello"|
    end

    test "param inside a NOT EXISTS predicate" do
      assert {:ok, query} =
               EctoQueryParser.apply(
                 EctoQueryParser.Test.Author,
                 "NOT posts.name == {{n}}",
                 params: %{"n" => "x"}
               )

      query_str = inspect(query)
      assert query_str =~ "not exists("
      assert query_str =~ ~s|^"x"|
    end

    test "missing param is a build error" do
      assert {:error, "missing required parameter: n"} = build("name == {{n}}", params: %{})
    end

    test "nil param value counts as unbound" do
      assert {:error, "missing required parameter: n"} =
               build("name == {{n}}", params: %{"n" => nil})
    end

    test "missing params option entirely is a build error" do
      assert {:error, "missing required parameter: n"} = build("name == {{n}}")
    end

    test "atom-keyed params maps are accepted" do
      assert {:ok, query} = build("name == {{n}}", params: %{n: "alice"})
      assert inspect(query) =~ ~s|^"alice"|
    end

    test "false and empty-string values are bound, not treated as missing" do
      assert {:ok, query} = build("active == {{flag}}", params: %{"flag" => false})
      assert inspect(query) =~ "active == ^false"

      assert {:ok, query} = build("name == {{n}}", params: %{"n" => ""})
      assert inspect(query) =~ ~s|name == ^""|
    end
  end

  describe "optional group pruning" do
    test "group with a bound param participates as if brackets were absent" do
      assert {:ok, query} =
               build(~s(status == "x" [[AND performed_on >= {{start}}]]),
                 params: %{"start" => "2026-01-01"}
               )

      query_str = inspect(query)
      assert query_str =~ ~s|status == ^"x"|
      assert query_str =~ " and "
      assert query_str =~ ":date"
    end

    test "group with an unbound param is pruned" do
      assert {:ok, query} =
               build(~s(status == "x" [[AND performed_on >= {{start}}]]), params: %{})

      query_str = inspect(query)
      assert query_str =~ ~s|status == ^"x"|
      refute query_str =~ "performed_on"
    end

    test "nil-valued param prunes the group" do
      assert {:ok, query} =
               build(~s(status == "x" [[AND performed_on >= {{start}}]]),
                 params: %{"start" => nil}
               )

      refute inspect(query) =~ "performed_on"
    end

    test "multi-param group requires every param bound" do
      filter = ~s(status == "x" [[AND age >= {{min}} AND age <= {{max}}]])

      assert {:ok, pruned} = build(filter, params: %{"min" => 18})
      refute inspect(pruned) =~ "age"

      assert {:ok, kept} = build(filter, params: %{"min" => 18, "max" => 65})
      query_str = inspect(kept)
      assert query_str =~ "age >= ^18"
      assert query_str =~ "age <= ^65"
    end

    test "groups prune independently" do
      filter = ~s(status == "x" [[AND age >= {{min}}]] [[AND name == {{n}}]])

      assert {:ok, query} = build(filter, params: %{"n" => "alice"})
      query_str = inspect(query)
      refute query_str =~ "age"
      assert query_str =~ ~s|name == ^"alice"|
    end

    test "a group containing no parameters is always included" do
      assert {:ok, query} = build(~s(status == "x" [[AND age >= 18]]), params: %{})
      query_str = inspect(query)
      assert query_str =~ "age >= ^18"

      # even without a :params option at all
      assert {:ok, query} = build(~s(status == "x" [[AND age >= 18]]))
      assert inspect(query) =~ "age >= ^18"
    end

    test "OR group prunes and participates correctly" do
      filter = ~s(role == "admin" [[OR role == {{alt}}]])

      assert {:ok, pruned} = build(filter, params: %{})
      refute inspect(pruned) =~ " or "

      assert {:ok, kept} = build(filter, params: %{"alt" => "mod"})
      assert inspect(kept) =~ " or "
    end

    test "fully pruned filter degenerates to WHERE true" do
      assert {:ok, query} = build("[[name == {{n}}]]", params: %{})
      assert inspect(query) =~ "where: ^true"
    end

    test "standalone group with bound param builds normally" do
      assert {:ok, query} = build("[[name == {{n}}]]", params: %{"n" => "alice"})
      assert inspect(query) =~ ~s|name == ^"alice"|
    end

    test "chain of standalone groups prunes each independently" do
      filter = "[[name == {{n}}]] [[AND age >= {{min}}]]"

      assert {:ok, query} = build(filter, params: %{"min" => 18})
      query_str = inspect(query)
      refute query_str =~ "name =="
      assert query_str =~ "age >= ^18"

      assert {:ok, query} = build(filter, params: %{})
      assert inspect(query) =~ "where: ^true"
    end

    test "group on a plural association merges into the same EXISTS when bound" do
      assert {:ok, query} =
               EctoQueryParser.apply(
                 EctoQueryParser.Test.Author,
                 ~s(posts.name == "a" [[AND posts.status == {{s}}]]),
                 params: %{"s" => "live"}
               )

      query_str = inspect(query)
      assert occurrences(query_str, "exists(") == 1
      assert query_str =~ ~s|^"live"|
    end

    test "group on a plural association is pruned when unbound" do
      assert {:ok, query} =
               EctoQueryParser.apply(
                 EctoQueryParser.Test.Author,
                 ~s(posts.name == "a" [[AND posts.status == {{s}}]]),
                 params: %{}
               )

      query_str = inspect(query)
      assert occurrences(query_str, "exists(") == 1
      refute query_str =~ "status"
    end

    test "pruning happens inside parentheses too" do
      assert {:ok, query} =
               build("(status == \"x\" [[AND age >= {{min}}]]) OR active == true", params: %{})

      query_str = inspect(query)
      refute query_str =~ "age"
      assert query_str =~ " or "
    end
  end

  describe "literal_transform option" do
    test ":default falls through to the existing coercion" do
      assert {:ok, query} =
               build(~s{performed_on >= "2026-05-20"}, literal_transform: season_transform())

      query_str = inspect(query)
      assert query_str =~ "type("
      assert query_str =~ ":date"
    end

    test "{:ok, term} replaces the value with no type/2 wrap" do
      assert {:ok, query} =
               build(~s{performed_on == "today"}, literal_transform: season_transform())

      query_str = inspect(query)
      assert query_str =~ "== ^~D[2026-07-28]"
      refute query_str =~ "type("
    end

    test "range with == compiles to >= lo AND <= hi" do
      assert {:ok, query} =
               build(~s{performed_on == "last year"}, literal_transform: season_transform())

      query_str = inspect(query)
      assert query_str =~ "performed_on >= ^~D[2025-01-01]"
      assert query_str =~ "performed_on <= ^~D[2025-12-31]"
      refute query_str =~ "type("
    end

    test "range with != compiles to NOT(>= lo AND <= hi)" do
      assert {:ok, query} =
               build(~s{performed_on != "last year"}, literal_transform: season_transform())

      query_str = inspect(query)
      assert query_str =~ "not ("
      assert query_str =~ ">= ^~D[2025-01-01]"
      assert query_str =~ "<= ^~D[2025-12-31]"
    end

    test "range with >= uses lo" do
      assert {:ok, query} =
               build(~s{performed_on >= "last year"}, literal_transform: season_transform())

      query_str = inspect(query)
      assert query_str =~ "performed_on >= ^~D[2025-01-01]"
      refute query_str =~ "2025-12-31"
    end

    test "range with > uses hi" do
      assert {:ok, query} =
               build(~s{performed_on > "last year"}, literal_transform: season_transform())

      query_str = inspect(query)
      assert query_str =~ "performed_on > ^~D[2025-12-31]"
      refute query_str =~ "2025-01-01"
    end

    test "range with <= uses hi" do
      assert {:ok, query} =
               build(~s{performed_on <= "last year"}, literal_transform: season_transform())

      assert inspect(query) =~ "performed_on <= ^~D[2025-12-31]"
    end

    test "range with < uses lo" do
      assert {:ok, query} =
               build(~s{performed_on < "last year"}, literal_transform: season_transform())

      assert inspect(query) =~ "performed_on < ^~D[2025-01-01]"
    end

    test "range literal on the left side flips the operator" do
      assert {:ok, query} =
               build(~s{"last year" <= performed_on}, literal_transform: season_transform())

      # "last year" <= performed_on  ≡  performed_on >= range  →  >= lo
      assert inspect(query) =~ "performed_on >= ^~D[2025-01-01]"
    end

    test "BETWEEN bounds resolve independently (low takes lo, high takes hi)" do
      assert {:ok, query} =
               build(~s{performed_on BETWEEN "last year" AND "today"},
                 literal_transform: season_transform()
               )

      query_str = inspect(query)
      assert query_str =~ ">= ^~D[2025-01-01]"
      assert query_str =~ "<= ^~D[2026-07-28]"
    end

    test "BETWEEN with ranges on both bounds uses low.lo and high.hi" do
      assert {:ok, query} =
               build(~s{performed_on BETWEEN "last year" AND "last year"},
                 literal_transform: season_transform()
               )

      query_str = inspect(query)
      assert query_str =~ ">= ^~D[2025-01-01]"
      assert query_str =~ "<= ^~D[2025-12-31]"
    end

    test "range for an IN list element is a build error" do
      assert {:error, msg} =
               build(~s{performed_on IN ["last year"]}, literal_transform: season_transform())

      assert msg =~ "IN list element"
      assert msg =~ "only supported for comparison and BETWEEN"
    end

    test "range for LIKE is a build error" do
      assert {:error, msg} =
               build(~s{name like "x"}, literal_transform: fn _, _ -> {:range, {1, 2}} end)

      assert msg =~ "LIKE"
      assert msg =~ "only supported for comparison and BETWEEN"
    end

    test "range for includes is a build error" do
      assert {:error, msg} =
               build(~s{tags includes "x"}, literal_transform: fn _, _ -> {:range, {1, 2}} end)

      assert msg =~ "includes"
      assert msg =~ "only supported for comparison and BETWEEN"
    end

    test "{:ok, term} for an IN list element replaces it and pins the list raw" do
      transform = fn
        :date, "today" -> {:ok, ~D[2026-07-28]}
        _, _ -> :default
      end

      assert {:ok, query} =
               build(~s{performed_on IN ["today", "2026-01-01"]}, literal_transform: transform)

      query_str = inspect(query)
      assert query_str =~ "~D[2026-07-28]"
      assert query_str =~ "2026-01-01"
      refute query_str =~ "type("
    end

    test "transform receives the leaf type on association paths" do
      assert {:ok, query} =
               build(~s{author.hired_on == "last year"}, literal_transform: season_transform())

      query_str = inspect(query)
      assert query_str =~ "left_join"
      assert query_str =~ ">= ^~D[2025-01-01]"
      assert query_str =~ "<= ^~D[2025-12-31]"
    end

    test "transform applies inside EXISTS subqueries" do
      assert {:ok, query} =
               EctoQueryParser.apply(
                 EctoQueryParser.Test.Author,
                 ~s{posts.performed_on == "last year"},
                 literal_transform: season_transform()
               )

      query_str = inspect(query)
      assert query_str =~ "exists("
      assert query_str =~ ">= ^~D[2025-01-01]"
    end

    test "transform applies to bound string parameter values" do
      assert {:ok, query} =
               build("performed_on == {{when}}",
                 params: %{"when" => "last year"},
                 literal_transform: season_transform()
               )

      query_str = inspect(query)
      assert query_str =~ ">= ^~D[2025-01-01]"
      assert query_str =~ "<= ^~D[2025-12-31]"
    end

    test "transform is called for string literals against :string fields too" do
      transform = fn
        :string, "admin-ish" -> {:ok, "admin"}
        _, _ -> :default
      end

      assert {:ok, query} = build(~s{role == "admin-ish"}, literal_transform: transform)
      assert inspect(query) =~ ~s|role == ^"admin"|
    end

    test "transform is not called when no field type is known" do
      transform = fn _type, _raw -> raise "should not be called" end

      # Schemaless query without type info in allowed_fields: no target type.
      import Ecto.Query, only: [from: 1]

      assert {:ok, _} =
               EctoQueryParser.apply(from("test_items"), ~s{name == "alice"},
                 literal_transform: transform
               )
    end

    test "transform is not called for non-string literals" do
      transform = fn _type, _raw -> raise "should not be called" end
      assert {:ok, _} = build("balance >= 100", literal_transform: transform)
    end

    test "invalid transform return is a build error" do
      assert {:error, msg} =
               build(~s{performed_on == "x"}, literal_transform: fn _, _ -> :bogus end)

      assert msg =~ "literal_transform must return"
    end

    test "NOT composes with range results" do
      assert {:ok, query} =
               build(~s{NOT performed_on == "last year"}, literal_transform: season_transform())

      query_str = inspect(query)
      assert query_str =~ "not ("
      assert query_str =~ ">= ^~D[2025-01-01]"
    end
  end

  defp occurrences(string, pattern) do
    string
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end
end
