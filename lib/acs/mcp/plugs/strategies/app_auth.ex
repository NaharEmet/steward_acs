defmodule Acs.MCP.Plugs.Strategies.AppAuth do
  @moduledoc """
  Authenticates MCP API keys by proxying to configured external apps.

  Reads the list of configured apps from `:apps` config (a map of app_name → config).
  Each app config supports:
    - `:base_url` — root URL of the app
    - `:api_key` — service-level API key for the app
    - `:auth_endpoint` — path to validate keys (default: `/api/auth/validate-key`)

  Uses the first app with a matching key by trying each app's validation endpoint.

  Example config:
      config :steward_acs, :apps, %{
        "my_app" => [
          base_url: System.get_env("MY_APP_URL"),
          api_key: System.get_env("MY_APP_API_KEY"),
          auth_endpoint: "/api/auth/validate-key"
        ]
      }
  """
  @behaviour Acs.MCP.Plugs.AuthStrategy
  require Logger

  @impl true
  def authenticate(key, _conn) do
    apps = Acs.Apps.Config.list_apps()

    apps
    |> Enum.find_value(fn {_app_name, config} ->
      base_url = Keyword.get(config, :base_url)
      endpoint = Keyword.get(config, :auth_endpoint, "/api/auth/validate-key")

      if base_url do
        url = "#{String.trim_trailing(base_url, "/")}/#{String.trim_leading(endpoint, "/")}"

        case Req.post(url, json: %{api_key: key}, receive_timeout: 5_000) do
          {:ok, %{status: 200, body: %{"valid" => true} = body}} ->
            Logger.debug("[MCPAuth] authenticated via app auth as #{body["role"]}")
            {:ok, %{role: body["role"], org_id: body["org_id"], permissions: Map.get(body, "permissions")}}

          {:ok, %{status: 200, body: body}} ->
            Logger.warning("[MCPAuth] invalid app key: #{inspect(body["reason"])}")
            nil

          {:ok, %{status: _status}} ->
            nil

          {:error, _reason} ->
            nil
        end
      end
    end) || {:error, "Authentication service unavailable"}
  end
end
