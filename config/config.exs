import Config

cors_origins =
  case System.get_env("CORS_ORIGINS") do
    nil -> ["http://localhost:4001"]
    "" -> ["http://localhost:4001"]
    origins -> origins |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

config :cors_plug,
  origin: cors_origins,
  max_age: 86_400,
  methods: ["GET", "POST", "PATCH", "OPTIONS"],
  headers: [
    "content-type",
    "authorization",
    "x-requested-with",
    "x-mcp-session-id",
    "x-log-ingest-key",
    "x-api-key"
  ],
  expose: ["x-mcp-session-id"]

config :steward_acs, :repo_adapter, Ecto.Adapters.SQLite3

config :steward_acs,
  namespace: Acs,
  ecto_repos: [Acs.Repo],
  generators: [timestamp_type: :utc_datetime]

config :steward_acs, AcsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AcsWeb.ErrorHTML, json: AcsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: AcsWeb.PubSub,
  code_reloader: false

config :phoenix, :json_library, Jason

config :steward_acs, dev_routes: false

compile_session_salt =
  cond do
    salt = System.get_env("COOKIE_SIGNING_SALT") ->
      salt

    secret = System.get_env("SECRET_KEY_BASE") ->
      :crypto.hash(:sha256, secret <> "cookie")
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    true ->
      "acs_cookie_session_v1"
  end

config :steward_acs,
       :session_signing_salt,
       compile_session_salt

config :steward_acs, :session_validity_in_days, 7

config :steward_acs, AcsWeb.PubSub, name: AcsWeb.PubSub

config :logger, :console, metadata: [:agent_id, :task_id, :file_path, :locked_by]

config :tailwind, :version, "3.4.3"

# Configure esbuild
config :esbuild,
  version: "0.21.5",
  steward_acs: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

import_config "#{config_env()}.exs"
