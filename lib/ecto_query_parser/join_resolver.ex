defmodule EctoQueryParser.JoinResolver do
  @moduledoc """
  Resolves dotted identifier paths (e.g., `author.name`, `post.author.company.name`)
  into Ecto dynamic expressions with named bindings and join specifications.
  """

  import Ecto.Query

  @doc """
  Resolves a dotted identifier name against a schema, returning a dynamic
  expression referencing the final field and a list of join specs needed.

  ## Join spec format

      %{binding: atom, assoc: atom, parent: :root | atom}

  ## Examples

      iex> resolve("author.name", MyApp.Post)
      {:ok, dynamic, [%{binding: :author, assoc: :author, parent: :root}]}

      iex> resolve("author.company.company_name", MyApp.Post)
      {:ok, dynamic, [
        %{binding: :author, assoc: :author, parent: :root},
        %{binding: :author__company, assoc: :company, parent: :author}
      ]}
  """
  def resolve(dotted_name, schema) do
    segments = String.split(dotted_name, ".")
    assoc_segments = Enum.slice(segments, 0..-2//1)
    field_name = List.last(segments)

    with {:ok, joins, final_binding} <- walk_associations(assoc_segments, schema, :root, [], []),
         {:ok, field_atom} <- existing_atom(field_name, "unknown field: #{field_name}") do
      expr = dynamic([{^final_binding, x}], field(x, ^field_atom))
      {:ok, expr, joins}
    end
  end

  defp walk_associations([], _schema, current_binding, _path, joins) do
    {:ok, Enum.reverse(joins), current_binding}
  end

  defp walk_associations([segment | rest], schema, parent, path, joins) do
    with {:ok, assoc_atom} <-
           existing_atom(segment, "unknown association: #{segment} on #{inspect(schema)}"),
         assoc when not is_nil(assoc) <- schema.__schema__(:association, assoc_atom) do
      new_path = path ++ [segment]
      # Safe: every segment in the path has been validated as a real
      # association above, so the binding atom space is bounded by the
      # schema's association graph.
      binding = new_path |> Enum.join("__") |> String.to_atom()

      join_spec = %{binding: binding, assoc: assoc_atom, parent: parent}
      next_schema = assoc.queryable

      walk_associations(rest, next_schema, binding, new_path, [join_spec | joins])
    else
      nil -> {:error, "unknown association: #{segment} on #{inspect(schema)}"}
      {:error, _} = error -> error
    end
  end

  # SECURITY: never create atoms from untrusted identifier segments — an
  # unknown name means an unknown association/field, not a new atom.
  defp existing_atom(name, error_message) do
    {:ok, String.to_existing_atom(name)}
  rescue
    ArgumentError -> {:error, error_message}
  end
end
