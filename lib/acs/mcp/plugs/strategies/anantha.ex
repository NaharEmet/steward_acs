defmodule Acs.MCP.Plugs.Strategies.Anantha do
  @behaviour Acs.MCP.Plugs.AuthStrategy
  require Logger

  @impl true
  def authenticate(key, _conn) do
    anantha_url =
      Application.get_env(:steward_acs, :anantha_url, "http://localhost:4000")

    url = "#{anantha_url}/api/auth/validate-key"

    case Req.post(url, json: %{api_key: key}, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{"valid" => true} = body}} ->
        Logger.debug("[MCPAuth] authenticated via Anantha key as #{body["role"]}")
        {:ok, %{role: body["role"], org_id: body["org_id"], permissions: Map.get(body, "permissions")}}

      {:ok, %{status: 200, body: body}} ->
        Logger.warning("[MCPAuth] invalid Anantha key: #{inspect(body["reason"])}")
        {:error, "Invalid API key"}

      {:ok, %{status: status}} ->
        {:error, "Unexpected status: #{status}"}

      {:error, reason} ->
        {:error, "Authentication service unavailable: #{inspect(reason)}"}
    end
  end
end
