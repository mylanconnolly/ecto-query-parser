ExUnit.start(exclude: [:integration])

if :integration in Keyword.get(ExUnit.configuration(), :include, []) do
  # Load schema via direct Postgrex connection (not sandboxed, so DDL persists)
  repo_config = Application.get_env(:ecto_query_parser, EctoQueryParser.TestRepo)

  {:ok, conn} =
    Postgrex.start_link(
      hostname: repo_config[:hostname],
      username: repo_config[:username],
      password: repo_config[:password],
      database: repo_config[:database]
    )

  structure = File.read!(Path.join([__DIR__, "..", "priv", "test", "structure.sql"]))

  structure
  |> String.split(";", trim: true)
  |> Enum.each(fn statement ->
    statement = String.trim(statement)

    if statement != "" do
      Postgrex.query!(conn, statement, [])
    end
  end)

  GenServer.stop(conn)

  # Now start the repo with sandbox pool for tests
  {:ok, _} = EctoQueryParser.TestRepo.start_link()
  Ecto.Adapters.SQL.Sandbox.mode(EctoQueryParser.TestRepo, :manual)
end
