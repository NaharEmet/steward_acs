defmodule Acs.MCP.Plugs.Strategies.Default do
  @behaviour Acs.MCP.Plugs.AuthStrategy
  require Logger

  @impl true
  def authenticate(key, conn) do
    cond do
      key && dev_key_valid?(key) ->
        Logger.debug("[MCPAuth] authenticated via dev key as admin")
        {:ok, %{role: "admin", org_id: nil, permissions: nil}}

      key && service_key_valid?(key) ->
        Logger.debug("[MCPAuth] authenticated via service key as admin")
        {:ok, %{role: "admin", org_id: nil, permissions: nil}}

      key ->
        {:error, "Invalid API key"}

      local_fallback_enabled?() && is_localhost?(conn) ->
        Logger.debug("[MCPAuth] localhost fallback — authenticated as admin")
        {:ok, %{role: "admin", org_id: nil, permissions: nil}}

      true ->
        {:error, "Missing or invalid API key"}
    end
  end

  defp dev_key_valid?(key) do
    case Application.fetch_env(:steward_acs, :mcp_api_key) do
      {:ok, dev_key} when is_binary(dev_key) and dev_key != "" ->
        binary_compare(key, dev_key)

      _ ->
        false
    end
  end

  defp service_key_valid?(key) do
    case Application.fetch_env(:steward_acs, :service_api_key) do
      {:ok, svc_key} when is_binary(svc_key) and svc_key != "" ->
        binary_compare(key, svc_key)

      _ ->
        false
    end
  end

  defp binary_compare(left, right) do
    # Timing-safe comparison — XOR all bytes and verify the result is zero
    if byte_size(left) == byte_size(right) do
      :crypto.exor(left, right) == :crypto.exor(left, left)
    else
      false
    end
  end

  defp local_fallback_enabled? do
    Application.get_env(:steward_acs, :mcp_auth_local_fallback, true)
  end

  defp is_localhost?(conn) do
    conn.remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]
  end
end
