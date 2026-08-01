defmodule Acs.MCP.Plugs.Strategies.Default do
  @behaviour Acs.MCP.Plugs.AuthStrategy
  require Logger

  @impl true
  def authenticate(key, conn) do
    cond do
      key && dev_key_valid?(key) ->
        Logger.debug("[MCPAuth] authenticated via shared MCP_API_KEY as admin")

        # Prefer ACS_DEVELOPER_NAME (setup/signup). Nil → Protocol pool name.
        # Named acs_dev_ keys take Strategies.Developer first (prod coding path).
        {:ok,
         %{
           role: "admin",
           org_id: nil,
           permissions: nil,
           agent_identity: Acs.Org.usable_developer_name(),
           authority_level_slug: shared_key_authority_level()
         }}

      key && service_key_valid?(key) ->
        Logger.debug("[MCPAuth] authenticated via service key")

        {:ok,
         %{
           role: "service",
           org_id: nil,
           permissions: nil,
           agent_identity: "service",
           authority_level_slug: service_key_authority_level()
         }}

      key ->
        {:error, "Invalid API key"}

      local_fallback_enabled?() && is_localhost?(conn) ->
        Logger.debug("[MCPAuth] localhost fallback — authenticated as admin")

        {:ok,
         %{
           role: "admin",
           org_id: nil,
           permissions: nil,
           agent_identity: Acs.Org.usable_developer_name(),
           authority_level_slug: shared_key_authority_level()
         }}

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

  defp binary_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp binary_compare(_, _), do: false

  defp local_fallback_enabled? do
    Application.get_env(:steward_acs, :mcp_auth_local_fallback, false)
  end

  defp is_localhost?(conn) do
    conn.remote_ip in [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]
  end

  # Shared MCP_API_KEY / localhost — typically the installer's key. Override with
  # :mcp_authority_level (e.g. "standard") to match a human member's clearance.
  defp shared_key_authority_level do
    case Application.get_env(:steward_acs, :mcp_authority_level) do
      slug when is_binary(slug) and slug != "" -> slug
      _ -> "high"
    end
  end

  defp service_key_authority_level do
    case Application.get_env(:steward_acs, :service_authority_level) do
      slug when is_binary(slug) and slug != "" -> slug
      _ -> "standard"
    end
  end
end
