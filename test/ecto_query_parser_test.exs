defmodule EctoQueryParserTest do
  use ExUnit.Case

  describe "strings" do
    test "parses simple string" do
      assert EctoQueryParser.parse(~s("foo")) == {:ok, {:string, "foo"}}
    end

    test "parses empty string" do
      assert EctoQueryParser.parse(~s("")) == {:ok, {:string, ""}}
    end

    test "parses string with spaces" do
      assert EctoQueryParser.parse(~s("hello world")) == {:ok, {:string, "hello world"}}
    end

    test "parses string with escaped double quote" do
      assert EctoQueryParser.parse(~s("say \\"hi\\"")) == {:ok, {:string, ~s(say "hi")}}
    end

    test "parses string with escaped backslash" do
      assert EctoQueryParser.parse(~s("back\\\\slash")) == {:ok, {:string, "back\\slash"}}
    end

    test "parses string with escaped newline" do
      assert EctoQueryParser.parse(~s("line\\none")) == {:ok, {:string, "line\none"}}
    end

    test "parses string with escaped tab" do
      assert EctoQueryParser.parse(~s("col\\tcol")) == {:ok, {:string, "col\tcol"}}
    end

    test "parses string with escaped carriage return" do
      assert EctoQueryParser.parse(~s("line\\rone")) == {:ok, {:string, "line\rone"}}
    end

    test "parses string with unicode characters" do
      assert EctoQueryParser.parse(~s("héllo wörld")) == {:ok, {:string, "héllo wörld"}}
    end

    test "parses string with surrounding whitespace" do
      assert EctoQueryParser.parse(~s(  "foo"  )) == {:ok, {:string, "foo"}}
    end
  end

  describe "integers" do
    test "parses single digit" do
      assert EctoQueryParser.parse("0") == {:ok, {:integer, 0}}
    end

    test "parses positive integer" do
      assert EctoQueryParser.parse("42") == {:ok, {:integer, 42}}
    end

    test "parses large integer" do
      assert EctoQueryParser.parse("1000000") == {:ok, {:integer, 1_000_000}}
    end

    test "parses negative integer" do
      assert EctoQueryParser.parse("-5") == {:ok, {:integer, -5}}
    end

    test "parses explicitly positive integer" do
      assert EctoQueryParser.parse("+10") == {:ok, {:integer, 10}}
    end

    test "parses integer with surrounding whitespace" do
      assert EctoQueryParser.parse("  123  ") == {:ok, {:integer, 123}}
    end
  end

  describe "floats" do
    test "parses simple float" do
      assert EctoQueryParser.parse("1.0") == {:ok, {:float, 1.0}}
    end

    test "parses float with multiple decimal places" do
      assert EctoQueryParser.parse("3.14") == {:ok, {:float, 3.14}}
    end

    test "parses float with trailing zeros" do
      assert EctoQueryParser.parse("3.50") == {:ok, {:float, 3.5}}
    end

    test "parses zero float" do
      assert EctoQueryParser.parse("0.0") == {:ok, {:float, 0.0}}
    end

    test "parses negative float" do
      assert EctoQueryParser.parse("-2.5") == {:ok, {:float, -2.5}}
    end

    test "parses explicitly positive float" do
      assert EctoQueryParser.parse("+1.5") == {:ok, {:float, 1.5}}
    end

    test "parses float with surrounding whitespace" do
      assert EctoQueryParser.parse("  3.14  ") == {:ok, {:float, 3.14}}
    end
  end

  describe "booleans" do
    test "parses lowercase true" do
      assert EctoQueryParser.parse("true") == {:ok, {:boolean, true}}
    end

    test "parses lowercase false" do
      assert EctoQueryParser.parse("false") == {:ok, {:boolean, false}}
    end

    test "parses uppercase TRUE" do
      assert EctoQueryParser.parse("TRUE") == {:ok, {:boolean, true}}
    end

    test "parses uppercase FALSE" do
      assert EctoQueryParser.parse("FALSE") == {:ok, {:boolean, false}}
    end

    test "parses titlecase True" do
      assert EctoQueryParser.parse("True") == {:ok, {:boolean, true}}
    end

    test "parses titlecase False" do
      assert EctoQueryParser.parse("False") == {:ok, {:boolean, false}}
    end

    test "parses boolean with surrounding whitespace" do
      assert EctoQueryParser.parse("  true  ") == {:ok, {:boolean, true}}
    end
  end

  describe "identifiers" do
    test "parses simple identifier" do
      assert EctoQueryParser.parse("name") == {:ok, {:identifier, "name"}}
    end

    test "parses identifier with underscore" do
      assert EctoQueryParser.parse("column_1") == {:ok, {:identifier, "column_1"}}
    end

    test "parses identifier starting with underscore" do
      assert EctoQueryParser.parse("_private") == {:ok, {:identifier, "_private"}}
    end

    test "parses single letter identifier" do
      assert EctoQueryParser.parse("x") == {:ok, {:identifier, "x"}}
    end

    test "parses identifier with uppercase letters" do
      assert EctoQueryParser.parse("MyColumn") == {:ok, {:identifier, "MyColumn"}}
    end

    test "parses identifier with digits" do
      assert EctoQueryParser.parse("col2") == {:ok, {:identifier, "col2"}}
    end

    test "parses dotted identifier" do
      assert EctoQueryParser.parse("table.column") == {:ok, {:identifier, "table.column"}}
    end

    test "parses identifier with surrounding whitespace" do
      assert EctoQueryParser.parse("  id  ") == {:ok, {:identifier, "id"}}
    end
  end

  describe "lists" do
    test "parses empty list" do
      assert EctoQueryParser.parse("[]") == {:ok, {:list, []}}
    end

    test "parses list of strings" do
      assert EctoQueryParser.parse(~s(["one", "two", "three"])) ==
               {:ok, {:list, [{:string, "one"}, {:string, "two"}, {:string, "three"}]}}
    end

    test "parses list of integers" do
      assert EctoQueryParser.parse("[1, 2, 3]") ==
               {:ok, {:list, [{:integer, 1}, {:integer, 2}, {:integer, 3}]}}
    end

    test "parses list of floats" do
      assert EctoQueryParser.parse("[1.0, 2.5, 3.14]") ==
               {:ok, {:list, [{:float, 1.0}, {:float, 2.5}, {:float, 3.14}]}}
    end

    test "parses list of booleans" do
      assert EctoQueryParser.parse("[true, false, TRUE]") ==
               {:ok, {:list, [{:boolean, true}, {:boolean, false}, {:boolean, true}]}}
    end

    test "parses list of identifiers" do
      assert EctoQueryParser.parse("[col_a, col_b]") ==
               {:ok, {:list, [{:identifier, "col_a"}, {:identifier, "col_b"}]}}
    end

    test "parses mixed-type list" do
      assert EctoQueryParser.parse(~s([1, "two", true, col])) ==
               {:ok,
                {:list,
                 [
                   {:integer, 1},
                   {:string, "two"},
                   {:boolean, true},
                   {:identifier, "col"}
                 ]}}
    end

    test "parses single-element list" do
      assert EctoQueryParser.parse("[42]") == {:ok, {:list, [{:integer, 42}]}}
    end

    test "parses list with extra whitespace" do
      assert EctoQueryParser.parse("[  1 ,  2  ,  3  ]") ==
               {:ok, {:list, [{:integer, 1}, {:integer, 2}, {:integer, 3}]}}
    end

    test "parses list with surrounding whitespace" do
      assert EctoQueryParser.parse("  [1, 2]  ") ==
               {:ok, {:list, [{:integer, 1}, {:integer, 2}]}}
    end

    test "parses nested list with function calls" do
      input = ~s{[TO_UPPER("a"), TO_LOWER("B")]}

      assert EctoQueryParser.parse(input) ==
               {:ok,
                {:list,
                 [
                   {:function, "to_upper", [{:string, "a"}]},
                   {:function, "to_lower", [{:string, "B"}]}
                 ]}}
    end
  end

  describe "functions" do
    test "parses function with single string argument" do
      assert EctoQueryParser.parse(~s{TO_UPPER("foo")}) ==
               {:ok, {:function, "to_upper", [{:string, "foo"}]}}
    end

    test "parses function with single identifier argument" do
      assert EctoQueryParser.parse("TO_UPPER(column_1)") ==
               {:ok, {:function, "to_upper", [{:identifier, "column_1"}]}}
    end

    test "parses lowercase function name" do
      assert EctoQueryParser.parse(~s{to_upper("foo")}) ==
               {:ok, {:function, "to_upper", [{:string, "foo"}]}}
    end

    test "parses mixed-case function name" do
      assert EctoQueryParser.parse(~s{To_Upper("foo")}) ==
               {:ok, {:function, "to_upper", [{:string, "foo"}]}}
    end

    test "parses function with no arguments" do
      assert EctoQueryParser.parse("now()") ==
               {:ok, {:function, "now", []}}
    end

    test "parses function with multiple arguments" do
      assert EctoQueryParser.parse(~s{concat("hello", " ", "world")}) ==
               {:ok,
                {:function, "concat",
                 [{:string, "hello"}, {:string, " "}, {:string, "world"}]}}
    end

    test "parses function with mixed argument types" do
      assert EctoQueryParser.parse(~s{func(1, "two", true, col)}) ==
               {:ok,
                {:function, "func",
                 [
                   {:integer, 1},
                   {:string, "two"},
                   {:boolean, true},
                   {:identifier, "col"}
                 ]}}
    end

    test "parses nested function calls" do
      assert EctoQueryParser.parse(~s{TO_UPPER(TRIM("  foo  "))}) ==
               {:ok,
                {:function, "to_upper",
                 [{:function, "trim", [{:string, "  foo  "}]}]}}
    end

    test "parses deeply nested function calls" do
      assert EctoQueryParser.parse(~s{a(b(c("x")))}) ==
               {:ok,
                {:function, "a",
                 [{:function, "b", [{:function, "c", [{:string, "x"}]}]}]}}
    end

    test "parses function with whitespace around parens" do
      assert EctoQueryParser.parse("func(  1  ,  2  )") ==
               {:ok, {:function, "func", [{:integer, 1}, {:integer, 2}]}}
    end

    test "parses function with surrounding whitespace" do
      assert EctoQueryParser.parse("  now()  ") ==
               {:ok, {:function, "now", []}}
    end

    test "parses function with list argument" do
      assert EctoQueryParser.parse(~s{coalesce(col, [1, 2, 3])}) ==
               {:ok,
                {:function, "coalesce",
                 [
                   {:identifier, "col"},
                   {:list, [{:integer, 1}, {:integer, 2}, {:integer, 3}]}
                 ]}}
    end
  end

  describe "operator ==" do
    test "identifier == string" do
      assert EctoQueryParser.parse(~s{name == "foo"}) ==
               {:ok, {:op, :==, {:identifier, "name"}, {:string, "foo"}}}
    end

    test "identifier == integer" do
      assert EctoQueryParser.parse("age == 42") ==
               {:ok, {:op, :==, {:identifier, "age"}, {:integer, 42}}}
    end

    test "identifier == float" do
      assert EctoQueryParser.parse("score == 3.14") ==
               {:ok, {:op, :==, {:identifier, "score"}, {:float, 3.14}}}
    end

    test "identifier == boolean" do
      assert EctoQueryParser.parse("active == true") ==
               {:ok, {:op, :==, {:identifier, "active"}, {:boolean, true}}}
    end

    test "with no spaces around operator" do
      assert EctoQueryParser.parse(~s{name=="foo"}) ==
               {:ok, {:op, :==, {:identifier, "name"}, {:string, "foo"}}}
    end

    test "with extra whitespace" do
      assert EctoQueryParser.parse("age  ==  42") ==
               {:ok, {:op, :==, {:identifier, "age"}, {:integer, 42}}}
    end

    test "function on left side" do
      assert EctoQueryParser.parse(~s{TO_UPPER(name) == "FOO"}) ==
               {:ok,
                {:op, :==, {:function, "to_upper", [{:identifier, "name"}]}, {:string, "FOO"}}}
    end

    test "function on right side" do
      assert EctoQueryParser.parse(~s{name == TO_LOWER("FOO")}) ==
               {:ok,
                {:op, :==, {:identifier, "name"},
                 {:function, "to_lower", [{:string, "FOO"}]}}}
    end

    test "dotted identifier" do
      assert EctoQueryParser.parse(~s{user.name == "alice"}) ==
               {:ok, {:op, :==, {:identifier, "user.name"}, {:string, "alice"}}}
    end
  end

  describe "operator !=" do
    test "identifier != string" do
      assert EctoQueryParser.parse(~s{status != "active"}) ==
               {:ok, {:op, :!=, {:identifier, "status"}, {:string, "active"}}}
    end

    test "identifier != integer" do
      assert EctoQueryParser.parse("count != 0") ==
               {:ok, {:op, :!=, {:identifier, "count"}, {:integer, 0}}}
    end

    test "with no spaces" do
      assert EctoQueryParser.parse(~s{x!=1}) ==
               {:ok, {:op, :!=, {:identifier, "x"}, {:integer, 1}}}
    end
  end

  describe "operator >=" do
    test "identifier >= integer" do
      assert EctoQueryParser.parse("age >= 18") ==
               {:ok, {:op, :>=, {:identifier, "age"}, {:integer, 18}}}
    end

    test "identifier >= float" do
      assert EctoQueryParser.parse("score >= 7.5") ==
               {:ok, {:op, :>=, {:identifier, "score"}, {:float, 7.5}}}
    end

    test "with no spaces" do
      assert EctoQueryParser.parse("x>=0") ==
               {:ok, {:op, :>=, {:identifier, "x"}, {:integer, 0}}}
    end
  end

  describe "operator <=" do
    test "identifier <= integer" do
      assert EctoQueryParser.parse("age <= 65") ==
               {:ok, {:op, :<=, {:identifier, "age"}, {:integer, 65}}}
    end

    test "identifier <= float" do
      assert EctoQueryParser.parse("price <= 9.99") ==
               {:ok, {:op, :<=, {:identifier, "price"}, {:float, 9.99}}}
    end

    test "with no spaces" do
      assert EctoQueryParser.parse("x<=100") ==
               {:ok, {:op, :<=, {:identifier, "x"}, {:integer, 100}}}
    end
  end

  describe "operator includes" do
    test "lowercase includes" do
      assert EctoQueryParser.parse(~s{tags includes "elixir"}) ==
               {:ok, {:op, :includes, {:identifier, "tags"}, {:string, "elixir"}}}
    end

    test "uppercase INCLUDES" do
      assert EctoQueryParser.parse(~s{tags INCLUDES "elixir"}) ==
               {:ok, {:op, :includes, {:identifier, "tags"}, {:string, "elixir"}}}
    end

    test "includes with integer" do
      assert EctoQueryParser.parse("ids includes 42") ==
               {:ok, {:op, :includes, {:identifier, "ids"}, {:integer, 42}}}
    end

    test "does not confuse includes_flag as operator" do
      assert EctoQueryParser.parse("includes_flag") ==
               {:ok, {:identifier, "includes_flag"}}
    end
  end

  describe "operator contains" do
    test "lowercase contains" do
      assert EctoQueryParser.parse(~s{name contains "alice"}) ==
               {:ok, {:op, :contains, {:identifier, "name"}, {:string, "alice"}}}
    end

    test "uppercase CONTAINS" do
      assert EctoQueryParser.parse(~s{name CONTAINS "alice"}) ==
               {:ok, {:op, :contains, {:identifier, "name"}, {:string, "alice"}}}
    end

    test "does not confuse contains_check as operator" do
      assert EctoQueryParser.parse("contains_check") ==
               {:ok, {:identifier, "contains_check"}}
    end
  end

  describe "operator like" do
    test "lowercase like" do
      assert EctoQueryParser.parse(~s{name like "%alice%"}) ==
               {:ok, {:op, :like, {:identifier, "name"}, {:string, "%alice%"}}}
    end

    test "uppercase LIKE" do
      assert EctoQueryParser.parse(~s{name LIKE "%alice%"}) ==
               {:ok, {:op, :like, {:identifier, "name"}, {:string, "%alice%"}}}
    end

    test "does not confuse liked as operator" do
      assert EctoQueryParser.parse("liked") ==
               {:ok, {:identifier, "liked"}}
    end
  end

  describe "operator ilike" do
    test "lowercase ilike" do
      assert EctoQueryParser.parse(~s{name ilike "%alice%"}) ==
               {:ok, {:op, :ilike, {:identifier, "name"}, {:string, "%alice%"}}}
    end

    test "uppercase ILIKE" do
      assert EctoQueryParser.parse(~s{name ILIKE "%alice%"}) ==
               {:ok, {:op, :ilike, {:identifier, "name"}, {:string, "%alice%"}}}
    end
  end

  describe "operator search" do
    test "lowercase search" do
      assert EctoQueryParser.parse(~s{body search "elixir programming"}) ==
               {:ok, {:op, :search, {:identifier, "body"}, {:string, "elixir programming"}}}
    end

    test "uppercase SEARCH" do
      assert EctoQueryParser.parse(~s{body SEARCH "elixir"}) ==
               {:ok, {:op, :search, {:identifier, "body"}, {:string, "elixir"}}}
    end

    test "does not confuse searchable as operator" do
      assert EctoQueryParser.parse("searchable") ==
               {:ok, {:identifier, "searchable"}}
    end
  end

  describe "operator edge cases" do
    test "operator with surrounding whitespace" do
      assert EctoQueryParser.parse(~s{  name == "foo"  }) ==
               {:ok, {:op, :==, {:identifier, "name"}, {:string, "foo"}}}
    end

    test "operator with list on right side" do
      assert EctoQueryParser.parse(~s{status includes [1, 2, 3]}) ==
               {:ok,
                {:op, :includes, {:identifier, "status"},
                 {:list, [{:integer, 1}, {:integer, 2}, {:integer, 3}]}}}
    end

    test "operator with functions on both sides" do
      input = ~s{TO_UPPER(name) == TO_UPPER("foo")}

      assert EctoQueryParser.parse(input) ==
               {:ok,
                {:op, :==,
                 {:function, "to_upper", [{:identifier, "name"}]},
                 {:function, "to_upper", [{:string, "foo"}]}}}
    end

    test "standalone value still works with operators defined" do
      assert EctoQueryParser.parse("42") == {:ok, {:integer, 42}}
      assert EctoQueryParser.parse(~s{"hello"}) == {:ok, {:string, "hello"}}
      assert EctoQueryParser.parse("true") == {:ok, {:boolean, true}}
      assert EctoQueryParser.parse("col") == {:ok, {:identifier, "col"}}
    end
  end

  describe "AND" do
    test "two comparisons" do
      assert EctoQueryParser.parse(~s{name == "alice" AND age == 30}) ==
               {:ok,
                {:and,
                 [
                   {:op, :==, {:identifier, "name"}, {:string, "alice"}},
                   {:op, :==, {:identifier, "age"}, {:integer, 30}}
                 ]}}
    end

    test "lowercase and" do
      assert EctoQueryParser.parse(~s{name == "alice" and age == 30}) ==
               {:ok,
                {:and,
                 [
                   {:op, :==, {:identifier, "name"}, {:string, "alice"}},
                   {:op, :==, {:identifier, "age"}, {:integer, 30}}
                 ]}}
    end

    test "three comparisons" do
      assert EctoQueryParser.parse(~s{a == 1 AND b == 2 AND c == 3}) ==
               {:ok,
                {:and,
                 [
                   {:op, :==, {:identifier, "a"}, {:integer, 1}},
                   {:op, :==, {:identifier, "b"}, {:integer, 2}},
                   {:op, :==, {:identifier, "c"}, {:integer, 3}}
                 ]}}
    end

    test "with different operators" do
      assert EctoQueryParser.parse(~s{age >= 18 AND status != "banned"}) ==
               {:ok,
                {:and,
                 [
                   {:op, :>=, {:identifier, "age"}, {:integer, 18}},
                   {:op, :!=, {:identifier, "status"}, {:string, "banned"}}
                 ]}}
    end

    test "with keyword operators" do
      assert EctoQueryParser.parse(~s{name contains "ali" AND tags includes "admin"}) ==
               {:ok,
                {:and,
                 [
                   {:op, :contains, {:identifier, "name"}, {:string, "ali"}},
                   {:op, :includes, {:identifier, "tags"}, {:string, "admin"}}
                 ]}}
    end

    test "does not confuse 'android' identifier with AND" do
      assert EctoQueryParser.parse(~s{android == true}) ==
               {:ok, {:op, :==, {:identifier, "android"}, {:boolean, true}}}
    end
  end

  describe "OR" do
    test "two comparisons" do
      assert EctoQueryParser.parse(~s{role == "admin" OR role == "superadmin"}) ==
               {:ok,
                {:or,
                 [
                   {:op, :==, {:identifier, "role"}, {:string, "admin"}},
                   {:op, :==, {:identifier, "role"}, {:string, "superadmin"}}
                 ]}}
    end

    test "lowercase or" do
      assert EctoQueryParser.parse(~s{a == 1 or b == 2}) ==
               {:ok,
                {:or,
                 [
                   {:op, :==, {:identifier, "a"}, {:integer, 1}},
                   {:op, :==, {:identifier, "b"}, {:integer, 2}}
                 ]}}
    end

    test "three comparisons" do
      assert EctoQueryParser.parse(~s{a == 1 OR b == 2 OR c == 3}) ==
               {:ok,
                {:or,
                 [
                   {:op, :==, {:identifier, "a"}, {:integer, 1}},
                   {:op, :==, {:identifier, "b"}, {:integer, 2}},
                   {:op, :==, {:identifier, "c"}, {:integer, 3}}
                 ]}}
    end

    test "does not confuse 'origin' identifier with OR" do
      assert EctoQueryParser.parse(~s{origin == "US"}) ==
               {:ok, {:op, :==, {:identifier, "origin"}, {:string, "US"}}}
    end
  end

  describe "AND/OR precedence" do
    test "AND binds tighter than OR" do
      # a == 1 OR b == 2 AND c == 3
      # should parse as: a == 1 OR (b == 2 AND c == 3)
      assert EctoQueryParser.parse("a == 1 OR b == 2 AND c == 3") ==
               {:ok,
                {:or,
                 [
                   {:op, :==, {:identifier, "a"}, {:integer, 1}},
                   {:and,
                    [
                      {:op, :==, {:identifier, "b"}, {:integer, 2}},
                      {:op, :==, {:identifier, "c"}, {:integer, 3}}
                    ]}
                 ]}}
    end

    test "AND binds tighter than OR (reversed)" do
      # a == 1 AND b == 2 OR c == 3
      # should parse as: (a == 1 AND b == 2) OR c == 3
      assert EctoQueryParser.parse("a == 1 AND b == 2 OR c == 3") ==
               {:ok,
                {:or,
                 [
                   {:and,
                    [
                      {:op, :==, {:identifier, "a"}, {:integer, 1}},
                      {:op, :==, {:identifier, "b"}, {:integer, 2}}
                    ]},
                   {:op, :==, {:identifier, "c"}, {:integer, 3}}
                 ]}}
    end
  end

  describe "grouping with parentheses" do
    test "grouped OR inside AND" do
      # (a == 1 OR b == 2) AND c == 3
      input = ~s{(a == 1 OR b == 2) AND c == 3}

      assert EctoQueryParser.parse(input) ==
               {:ok,
                {:and,
                 [
                   {:or,
                    [
                      {:op, :==, {:identifier, "a"}, {:integer, 1}},
                      {:op, :==, {:identifier, "b"}, {:integer, 2}}
                    ]},
                   {:op, :==, {:identifier, "c"}, {:integer, 3}}
                 ]}}
    end

    test "two grouped ANDs joined by OR" do
      input = ~s{(a == 1 AND b == 2) OR (c == 3 AND d == 4)}

      assert EctoQueryParser.parse(input) ==
               {:ok,
                {:or,
                 [
                   {:and,
                    [
                      {:op, :==, {:identifier, "a"}, {:integer, 1}},
                      {:op, :==, {:identifier, "b"}, {:integer, 2}}
                    ]},
                   {:and,
                    [
                      {:op, :==, {:identifier, "c"}, {:integer, 3}},
                      {:op, :==, {:identifier, "d"}, {:integer, 4}}
                    ]}
                 ]}}
    end

    test "nested parentheses" do
      input = ~s{((a == 1 OR b == 2) AND c == 3) OR d == 4}

      assert EctoQueryParser.parse(input) ==
               {:ok,
                {:or,
                 [
                   {:and,
                    [
                      {:or,
                       [
                         {:op, :==, {:identifier, "a"}, {:integer, 1}},
                         {:op, :==, {:identifier, "b"}, {:integer, 2}}
                       ]},
                      {:op, :==, {:identifier, "c"}, {:integer, 3}}
                    ]},
                   {:op, :==, {:identifier, "d"}, {:integer, 4}}
                 ]}}
    end

    test "redundant parentheses around single expression" do
      assert EctoQueryParser.parse(~s{(name == "alice")}) ==
               {:ok, {:op, :==, {:identifier, "name"}, {:string, "alice"}}}
    end

    test "whitespace inside parentheses" do
      input = ~s{(  a == 1  OR  b == 2  )}

      assert EctoQueryParser.parse(input) ==
               {:ok,
                {:or,
                 [
                   {:op, :==, {:identifier, "a"}, {:integer, 1}},
                   {:op, :==, {:identifier, "b"}, {:integer, 2}}
                 ]}}
    end

    test "complex mixed expression" do
      input = ~s{(a == 1 AND b == 2) OR (c == 3 AND d == 4) OR e == 5}

      assert EctoQueryParser.parse(input) ==
               {:ok,
                {:or,
                 [
                   {:and,
                    [
                      {:op, :==, {:identifier, "a"}, {:integer, 1}},
                      {:op, :==, {:identifier, "b"}, {:integer, 2}}
                    ]},
                   {:and,
                    [
                      {:op, :==, {:identifier, "c"}, {:integer, 3}},
                      {:op, :==, {:identifier, "d"}, {:integer, 4}}
                    ]},
                   {:op, :==, {:identifier, "e"}, {:integer, 5}}
                 ]}}
    end

    test "with keyword operators and functions" do
      input = ~s{name like "%alice%" AND (role == "admin" OR role == "mod")}

      assert EctoQueryParser.parse(input) ==
               {:ok,
                {:and,
                 [
                   {:op, :like, {:identifier, "name"}, {:string, "%alice%"}},
                   {:or,
                    [
                      {:op, :==, {:identifier, "role"}, {:string, "admin"}},
                      {:op, :==, {:identifier, "role"}, {:string, "mod"}}
                    ]}
                 ]}}
    end
  end

  describe "error cases" do
    test "returns error for empty input" do
      assert {:error, _} = EctoQueryParser.parse("")
    end

    test "returns error for unterminated string" do
      assert {:error, _} = EctoQueryParser.parse(~s{"unterminated})
    end

    test "returns error for unmatched bracket" do
      assert {:error, _} = EctoQueryParser.parse("[1, 2")
    end

    test "returns error for unmatched paren" do
      assert {:error, _} = EctoQueryParser.parse("func(1, 2")
    end

    test "returns error for trailing content" do
      assert {:error, _} = EctoQueryParser.parse("42 extra")
    end

    test "returns error for identifier starting with digit" do
      # "1abc" would parse "1" as integer, then fail on "abc" trailing
      assert {:error, _} = EctoQueryParser.parse("1abc")
    end

    test "returns error for unclosed grouping paren" do
      assert {:error, _} = EctoQueryParser.parse("(a == 1 AND b == 2")
    end

    test "returns error for dangling AND" do
      assert {:error, _} = EctoQueryParser.parse("a == 1 AND")
    end

    test "returns error for dangling OR" do
      assert {:error, _} = EctoQueryParser.parse("a == 1 OR")
    end
  end
end
