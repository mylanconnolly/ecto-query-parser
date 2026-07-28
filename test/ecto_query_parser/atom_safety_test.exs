defmodule EctoQueryParser.AtomSafetyTest do
  # async: false is load-bearing: :erlang.system_info(:atom_count) is VM-global,
  # and under async ExUnit other test files load modules concurrently — a module
  # load creates thousands of atoms and makes count-based assertions flaky
  # (observed on the Elixir 1.18/OTP 27 CI cell). Sync test modules run after
  # every async module has finished, so the VM is quiet while we measure.
  use ExUnit.Case, async: false

  import Ecto.Query

  alias EctoQueryParser.Test.TestSchema

  # The filter language exists to process untrusted input, so no code path may
  # call String.to_atom/1 on it: a hostile stream of unique identifiers would
  # otherwise exhaust the BEAM atom table and crash the node.
  #
  # Two complementary assertions per resolution path:
  #
  # 1. Deterministic: sampled hostile names must not exist as atoms afterward
  #    (String.to_existing_atom/1 raises). Immune to unrelated atom churn.
  # 2. Count-based: the atom table stays nearly constant across the hammering
  #    loop, after a warm-up round so lazily-loaded runtime modules don't
  #    pollute the measurement.

  @hostile_rounds 1000
  @max_atom_growth 50

  defp build(query_string, opts \\ []) do
    EctoQueryParser.apply(TestSchema, query_string, opts)
  end

  defp atom_growth(fun) do
    # Warm-up: run one round first so module loads and other lazy
    # initialization triggered by this code path don't count as growth.
    fun.(0)

    before = :erlang.system_info(:atom_count)
    for i <- 1..@hostile_rounds, do: fun.(i)
    :erlang.system_info(:atom_count) - before
  end

  defp refute_atoms_exist(names) do
    for name <- names do
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  test "unique dotted association paths error without creating atoms" do
    growth =
      atom_growth(fn i ->
        assert {:error, _} = build("nonexistent_assoc_#{i}.nonexistent_field_#{i} == 1")
      end)

    refute_atoms_exist(["nonexistent_assoc_17", "nonexistent_field_902"])
    assert growth < @max_atom_growth
  end

  test "unique single-segment fields error without creating atoms" do
    growth =
      atom_growth(fn i ->
        assert {:error, _} = build("nonexistent_field_solo_#{i} == 1")
      end)

    refute_atoms_exist(["nonexistent_field_solo_444"])
    assert growth < @max_atom_growth
  end

  test "hostile leaf fields on a real association error without creating atoms" do
    growth =
      atom_growth(fn i ->
        assert {:error, _} = build("author.hostile_realleaf_#{i} == 1")
      end)

    refute_atoms_exist(["hostile_realleaf_733"])
    assert growth < @max_atom_growth
  end

  test "unique dotted paths against an allowlist error without creating atoms" do
    growth =
      atom_growth(fn i ->
        assert {:error, "field not allowed: " <> _} =
                 build("unlisted_a_#{i}.unlisted_b_#{i} == 1",
                   allowed_fields: [name: :string, metadata: :map]
                 )
      end)

    refute_atoms_exist(["unlisted_a_31", "unlisted_b_878"])
    assert growth < @max_atom_growth
  end

  test "unique JSON path keys never become atoms" do
    growth =
      atom_growth(fn i ->
        # JSON sub-paths on a :map field are legal — they compile to
        # json_extract_path with STRING keys, so even successful builds must
        # not create atoms from the path segments.
        assert {:ok, _} = build(~s{metadata.hostile_json_#{i} == "x"})
      end)

    refute_atoms_exist(["hostile_json_512"])
    assert growth < @max_atom_growth
  end

  test "unique fields in allowlisted mode error without creating atoms" do
    growth =
      atom_growth(fn i ->
        assert {:error, _} =
                 build("unallowed_flat_#{i} == 1", allowed_fields: [name: :string])
      end)

    refute_atoms_exist(["unallowed_flat_256"])
    assert growth < @max_atom_growth
  end

  test "unique dotted paths in schemaless mode error without creating atoms" do
    author =
      {:belongs_to,
       table: "authors", owner_key: :author_id, related_key: :id, fields: [name: :string]}

    growth =
      atom_growth(fn i ->
        assert {:error, _} =
                 EctoQueryParser.apply(
                   from("test_items"),
                   "author.schemaless_leaf_#{i} == 1",
                   allowed_fields: [author: author]
                 )
      end)

    refute_atoms_exist(["schemaless_leaf_640"])
    assert growth < @max_atom_growth
  end
end
