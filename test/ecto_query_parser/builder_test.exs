defmodule EctoQueryParser.BuilderTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  defmodule Company do
    use Ecto.Schema

    schema "companies" do
      field :company_name, :string
    end
  end

  defmodule Author do
    use Ecto.Schema

    schema "authors" do
      field :name, :string
      field :email, :string
      belongs_to :company, Company
      has_many :posts, EctoQueryParser.BuilderTest.TestSchema
    end
  end

  defmodule TestSchema do
    use Ecto.Schema

    schema "test_items" do
      field :name, :string
      field :age, :integer
      field :score, :float
      field :active, :boolean
      field :tags, {:array, :string}
      field :body, :string
      field :role, :string
      field :status, :string
      field :metadata, :map
      belongs_to :author, Author
    end
  end

  defp build(query_string, opts \\ []) do
    EctoQueryParser.apply(TestSchema, query_string, opts)
  end

  defp inspect_query({:ok, query}) do
    inspect(query)
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
    test "parse error" do
      assert {:error, _reason} = build("")
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
               schemaless_build(~s{name == "alice"}, allowed_fields: [name: :string, age: :integer])

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
end
