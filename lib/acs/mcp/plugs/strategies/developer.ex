defmodule Acs.MCP.Plugs.Strategies.Developer do
  @moduledoc """
  Authentication strategy for ACS developer API keys.

  Keys start with `acs_dev_` prefix and are validated against
  the `Acs.Developers` context which stores SHA-256 hashes.

  The `org_id` field in the result is repurposed to carry the
  cluster label — this is intentional: downstream code reads
  `agent_org_id` as the cluster for developer-authenticated requests.
  """
  @behaviour Acs.MCP.Plugs.AuthStrategy
  require Logger

  @key_prefix "acs_dev_"

  @impl true
  def authenticate(key, _conn) do
    if is_binary(key) and String.starts_with?(key, @key_prefix) do
      case Acs.Developers.authenticate(key) do
        {:ok, result} ->
          Logger.debug(
            "[MCPAuth] authenticated via developer key: role=#{result.role} cluster=#{result.cluster}"
          )

          {:ok,
           %{
             role: result.role,
             org_id: result.cluster,
             permissions: nil,
             agent_identity: result.developer_name,
             allowed_teams: result[:allowed_teams],
             allowed_projects: result[:allowed_projects]
           }}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, "Not a developer key"}
    end
  end
end
