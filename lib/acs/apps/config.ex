defmodule Acs.Apps.Config do
  @moduledoc """
  Runtime app configuration from environment variables.

  Discover apps from `CONFIGURED_APPS` env var (space- or comma-separated names),
  then reads per-app config from `APP_<NAME>_*` env vars.

  Supported config keys and their env var mappings:

  | Config           | Env var                         | Default         | Description                       |
  |------------------|---------------------------------|-----------------|-----------------------------------|
  | `base_url`       | `APP_<NAME>_URL`                | — (required)    | Root URL of the app               |
  | `api_key`        | `APP_<NAME>_API_KEY`            | —               | Service API key                   |
  | `auth_endpoint`  | `APP_<NAME>_AUTH_ENDPOINT`      | —               | Path to validate API keys         |
  | `auth_header_name` | `APP_<NAME>_AUTH_HEADER_NAME` | `"authorization"` | Header name for API key auth    |
  | `auth_header_scheme` | `APP_<NAME>_AUTH_HEADER_SCHEME` | `"Bearer"` | Auth scheme prefix or `""` for raw key |
  | `timeout_ms`     | `APP_<NAME>_TIMEOUT_MS`         | `30000`         | Request timeout in milliseconds    |

  MCP tools for runtime CRUD: `app_list`, `app_configure`, `app_remove`.

  Example `.env`:
      CONFIGURED_APPS=my_app
      APP_MY_APP_URL=http://localhost:4000
      APP_MY_APP_API_KEY=sk_...
      APP_MY_APP_AUTH_HEADER_NAME=x-api-key
      APP_MY_APP_AUTH_HEADER_SCHEME=
      APP_MY_APP_TIMEOUT_MS=15000

  Example `docker-compose.yaml`:
      environment:
        CONFIGURED_APPS: "my_app myapp2"
        APP_MY_APP_URL: "http://my_app:4000"
        APP_MY_APP_API_KEY: "${MY_APP_API_KEY}"
        APP_MY_APP_AUTH_HEADER_NAME: "authorization"
        APP_MY_APP_AUTH_HEADER_SCHEME: "Bearer"
        APP_MYAPP_URL: "http://myapp:5000"
        APP_MYAPP_API_KEY: "key123"
        APP_MYAPP_AUTH_HEADER_NAME: "x-api-key"
        APP_MYAPP_AUTH_HEADER_SCHEME: ""
  """

  use GenServer
  require Logger

  @table :apps_config

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns a map of configured apps for one organization."
  def list_apps(org \\ Acs.Org.current()) when is_binary(org) do
    case :ets.info(@table, :name) do
      :undefined ->
        %{}

      _ ->
        @table
        |> :ets.match_object({{org, :_}, :_})
        |> Map.new(fn {{^org, name}, config} -> {name, config} end)
    end
  end

  @doc "Returns an organization's config for a specific app, or nil."
  def get_app(name, org \\ Acs.Org.current()) when is_binary(name) and is_binary(org) do
    case :ets.lookup(@table, {org, name}) do
      [{{^org, ^name}, config}] -> config
      [] -> nil
    end
  end

  @doc "Add or update an organization-scoped app config at runtime."
  def configure_app(name, config, org \\ Acs.Org.current())
      when is_binary(name) and is_list(config) and is_binary(org) do
    GenServer.call(__MODULE__, {:configure, org, name, config}, :infinity)
  end

  @doc "Remove an organization-scoped app config at runtime."
  def remove_app(name, org \\ Acs.Org.current()) when is_binary(name) and is_binary(org) do
    GenServer.call(__MODULE__, {:remove, org, name}, :infinity)
  end

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    case :ets.info(@table, :name) do
      :undefined ->
        :ets.new(@table, [
          :set,
          :named_table,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end

    discover_from_env()

    Logger.info("[Apps.Config] Loaded #{map_size(list_apps())} app(s)")
    {:ok, %{}}
  end

  @impl true
  def handle_call({:configure, org, name, config}, _from, state) do
    :ets.insert(@table, {{org, name}, config})
    Logger.info("[Apps.Config] Configured app: #{name} for org #{org}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:remove, org, name}, _from, state) do
    :ets.delete(@table, {org, name})
    Logger.info("[Apps.Config] Removed app: #{name} for org #{org}")
    {:reply, :ok, state}
  end

  # -- Env var discovery --

  defp discover_from_env do
    case System.get_env("CONFIGURED_APPS") do
      nil ->
        Logger.info("[Apps.Config] No CONFIGURED_APPS set, no apps configured")
        :ok

      "" ->
        :ok

      names ->
        names
        |> String.split(~r{[\s,]+}, trim: true)
        |> Enum.map(&String.downcase/1)
        |> Enum.each(&load_from_env/1)
    end
  end

  defp load_from_env(name) do
    legacy_prefix = String.upcase(name)
    prefix = "APP_#{legacy_prefix}"

    env = fn suffix ->
      System.get_env("#{prefix}_#{suffix}") || System.get_env("#{legacy_prefix}_#{suffix}")
    end

    base_url = env.("URL")
    api_key = env.("API_KEY")
    auth_endpoint = env.("AUTH_ENDPOINT")
    auth_header_name = env.("AUTH_HEADER_NAME")
    auth_header_scheme = env.("AUTH_HEADER_SCHEME")
    timeout_ms = env.("TIMEOUT_MS")

    config =
      []
      |> then(fn c -> if base_url, do: Keyword.put(c, :base_url, base_url), else: c end)
      |> then(fn c -> if api_key, do: Keyword.put(c, :api_key, api_key), else: c end)
      |> then(fn c ->
        if auth_endpoint, do: Keyword.put(c, :auth_endpoint, auth_endpoint), else: c
      end)
      |> then(fn c ->
        if auth_header_name, do: Keyword.put(c, :auth_header_name, auth_header_name), else: c
      end)
      |> then(fn c ->
        if auth_header_scheme,
          do: Keyword.put(c, :auth_header_scheme, auth_header_scheme),
          else: c
      end)
      |> then(fn c ->
        if timeout_ms, do: Keyword.put(c, :timeout_ms, String.to_integer(timeout_ms)), else: c
      end)

    if base_url do
      org = Acs.Org.configured()
      :ets.insert(@table, {{org, name}, config})
      Logger.debug("[Apps.Config] Discovered app: #{name} for org #{org} (#{base_url})")
    else
      Logger.warning(
        "[Apps.Config] App '#{name}' listed in CONFIGURED_APPS but no #{prefix}_URL set, skipping"
      )
    end
  end
end
