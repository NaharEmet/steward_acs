import Config

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
  live_view: [signing_salt: "acs_placeholder"],
  code_reloader: false

config :phoenix, :json_library, Jason

config :steward_acs, AcsWeb.PubSub, name: AcsWeb.PubSub

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
