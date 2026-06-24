import Config

config :steward_acs, :repo_adapter, Ecto.Adapters.SQLite3

# SQLite test database
config :steward_acs, Acs.Repo,
  database: Path.expand("../../tmp/acs_test.db", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5,
  show_sensitive_data_on_connection_error: true

# Print only warnings and errors during test
config :logger, level: :warning

# No MCP server during tests — transport kept for compile_env consistency
config :steward_acs, Acs.MCP.Server, enabled: false, transport: :http
