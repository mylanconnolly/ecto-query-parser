import Config

config :ecto_query_parser, EctoQueryParser.TestRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "ecto_query_parser_test",
  pool: Ecto.Adapters.SQL.Sandbox
