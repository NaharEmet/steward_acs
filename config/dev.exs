import Config

config :steward_acs, :repo_adapter, Ecto.Adapters.SQLite3

# Load .env file at runtime — must happen before any OTP apps start
# (needed for ENCRYPTION_KEY which root app's Vault reads at init)
if File.exists?(".env") do
  File.read!(".env")
  |> String.split("\n")
  |> Enum.each(fn line ->
    line = String.trim(line)

    if String.length(line) > 0 and not String.starts_with?(line, "#") do
      case String.split(line, "=", parts: 2) do
        [key, value] ->
          System.put_env(String.trim(key), String.trim(value))

        _ ->
          :ok
      end
    end
  end)
end

config :steward_acs, Acs.Repo,
  database: System.get_env("DATABASE_PATH") || Path.expand("../../var/acs.sqlite", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :steward_acs, AcsWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4001],
  check_origin: false,
  code_reloader: false,
  watchers: [
    esbuild:
      {Esbuild, :install_and_run, [:steward_acs, ~w(--sourcemap=inline --watch)]}
  ],
  secret_key_base: "+20ql2Vv+vFOZn3b43kTHCRl7ND16dQv5trZpXOJC8VzcBuHG7s41dBoZf04Opnj"

config :steward_acs, Acs.MCP.Server,
  enabled: true,
  transport: :http

config :logger, level: :info

config :steward_acs, Acs.MCP.ToolLoader,
  tools_paths: [
    Path.expand("../../../anantha/acstools", __DIR__),
    Path.expand("../../../acs/acstools", __DIR__)
  ]

config :steward_acs, Acs.Cognition.Loader,
  specs_path: Path.expand("../../../_build/acs/specs", __DIR__)

config :steward_acs, :mcp_api_key, "dev-api-key"
config :steward_acs, :service_api_key, "dev-service-key"
config :steward_acs, :mcp_auth_local_fallback, true
config :steward_acs, :cluster_name, "dev"

config :steward_acs, :auth_strategies, [
  Acs.MCP.Plugs.Strategies.Developer,
  Acs.MCP.Plugs.Strategies.Default
]

config :steward_acs, :anantha_url, "http://localhost:4000"

# Anantha memory query gateway
config :steward_acs, :anantha,
  base_url: System.get_env("ANANTHA_URL") || "http://localhost:4000",
  api_key: System.get_env("ANANTHA_API_KEY"),
  org_id: nil
