import Config

config :steward_acs, :repo_adapter, Ecto.Adapters.Postgres

config :steward_acs, Acs.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: System.get_env("PGDATABASE", "acs_prod"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE", "10")),
  ssl: System.get_env("PGSSL", "false") == "true"

config :steward_acs, AcsWeb.Endpoint,
  url: [host: "localhost"],
  cache_static_manifest: "priv/static/cache_manifest.json"

config :steward_acs, Acs.MCP.Server,
  enabled: true,
  transport: :http

config :logger, level: :info

config :steward_acs, Acs.MCP.ToolLoader,
  tools_paths: [
    System.get_env("ANANTHA_TOOLS_PATH", "/app/anantha/acstools/"),
    System.get_env("ACS_TOOLS_PATH", "/app/acs/acstools/")
  ]
