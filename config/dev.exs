import Config

config :steward_acs, :repo_adapter, Ecto.Adapters.SQLite3

config :steward_acs, Acs.Repo,
  database: System.get_env("DATABASE_PATH") || Path.expand("../var/acs.sqlite", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

secret_key_base =
  System.get_env("SECRET_KEY_BASE") ||
    :crypto.strong_rand_bytes(64) |> Base.encode64()

signing_salt =
  System.get_env("SESSION_SIGNING_SALT") ||
    :crypto.hash(:sha256, secret_key_base)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)

dev_port = String.to_integer(System.get_env("PORT", "4001"))

config :steward_acs, AcsWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: dev_port],
  check_origin: [
    "//localhost:#{dev_port}",
    "//127.0.0.1:#{dev_port}",
    "//[::1]:#{dev_port}",
    "//*.localhost:#{dev_port}"
  ],
  code_reloader: false,
  watchers: [],
  live_view: [signing_salt: signing_salt],
  secret_key_base: secret_key_base

config :logger, level: :info

config :steward_acs, Acs.MCP.ToolLoader,
  tools_paths: [
    # Path.expand("../../../anantha/acstools", __DIR__),
    Path.expand("../../../acs/acstools", __DIR__)
  ]

config :steward_acs, Acs.Cognition.Loader,
  specs_path: Path.expand("../../../_build/acs/specs", __DIR__)

config :steward_acs, :mcp_api_key, System.get_env("MCP_API_KEY", "dev-mcp-key-change-me")
config :steward_acs, :service_api_key, System.get_env("SERVICE_API_KEY", "dev-svc-key-change-me")
config :steward_acs, :log_ingest_key, System.get_env("LOG_INGEST_KEY", "dev-log-key-change-me")

config :steward_acs,
       :mcp_auth_local_fallback,
       System.get_env("MCP_AUTH_LOCAL_FALLBACK", "false") == "true"

config :steward_acs,
       :org_name,
       System.get_env("ACS_ORG_NAME") || System.get_env("ACS_CLUSTER_NAME", "dev")
config :steward_acs, :admin_emails, [System.get_env("ACS_ADMIN_EMAIL", "admin@localhost")]

config :steward_acs, :allowed_paths, ["/tmp"]
config :steward_acs, :allowed_commands, ~w(echo ls cat)

config :steward_acs, dev_routes: true

config :steward_acs, :auth_strategies, [
  Acs.MCP.Plugs.Strategies.Developer,
  Acs.MCP.Plugs.Strategies.Default
]

# Apps discovered at runtime from CONFIGURED_APPS + APP_<NAME>_URL env vars.
# Example (in .env or docker-compose):
#   CONFIGURED_APPS=my_app
#   APP_ANANTHA_URL=http://localhost:4000
#   APP_ANANTHA_API_KEY=sk_...
#   APP_ANANTHA_AUTH_ENDPOINT=/api/auth/validate-key
# See Acs.Apps.Config for details.
