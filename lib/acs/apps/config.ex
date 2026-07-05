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

  @doc "Returns a map of all configured apps (app_name -> config keyword list)."
  def list_apps do
    case :ets.info(@table, :name) do
      :undefined -> %{}
      _ -> :ets.tab2list(@table) |> Map.new(fn {k, v} -> {k, v} end)
    end
  end

  @doc "Returns config keyword list for a specific app, or nil."
  def get_app(name) when is_binary(name) do
    case :ets.lookup(@table, name) do
      [{^name, config}] -> config
      [] -> nil
    end
  end

  @doc "Add or update an app config at runtime. Returns :ok."
  def configure_app(name, config) when is_binary(name) and is_list(config) do
    GenServer.call(__MODULE__, {:configure, name, config}, :infinity)
  end

  @doc "Remove an app config at runtime. Returns :ok."
  def remove_app(name) when is_binary(name) do
    GenServer.call(__MODULE__, {:remove, name}, :infinity)
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
  def handle_call({:configure, name, config}, _from, state) do
    :ets.insert(@table, {name, config})
    Logger.info("[Apps.Config] Configured app: #{name}")
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:remove, name}, _from, state) do
    :ets.delete(@table, name)
    Logger.info("[Apps.Config] Removed app: #{name}")
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
    prefix = String.upcase(name)

    base_url = System.get_env("#{prefix}_URL")
    api_key = System.get_env("#{prefix}_API_KEY")
    auth_endpoint = System.get_env("#{prefix}_AUTH_ENDPOINT")
    auth_header_name = System.get_env("#{prefix}_AUTH_HEADER_NAME")
    auth_header_scheme = System.get_env("#{prefix}_AUTH_HEADER_SCHEME")
    timeout_ms = System.get_env("#{prefix}_TIMEOUT_MS")

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
      :ets.insert(@table, {name, config})
      Logger.debug("[Apps.Config] Discovered app: #{name} (#{base_url})")
    else
      Logger.warning(
        "[Apps.Config] App '#{name}' listed in CONFIGURED_APPS but no #{prefix}_URL set, skipping"
      )
    end
  end
end
