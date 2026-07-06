defmodule Acs.MCP.Plugs.Strategies.OAuthBearer do
  @moduledoc """
  Auth0 / OIDC Bearer token authentication for MCP OAuth (Claude Connectors).

  Validates JWT access tokens against the Auth0 JWKS endpoint and maps claims
  to ACS agent role/identity. Equivalent to ASP.NET `AddJwtBearer` with
  `Authority` + `Audience`.
  """
  @behaviour Acs.MCP.Plugs.AuthStrategy

  alias Acs.MCP.OAuth.{Config, JWKS}

  require Logger

  @impl true
  def authenticate(_key, conn) do
    with true <- Config.enabled?(),
         token when is_binary(token) <- bearer_token(conn),
         {:ok, claims} <- JWKS.verify(token) do
      {:ok, map_claims(claims)}
    else
      false -> {:error, "OAuth not configured"}
      nil -> {:error, "Not a Bearer token"}
      {:error, reason} -> {:error, reason}
    end
  end

  defp bearer_token(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] when byte_size(token) > 0 -> token
      _ -> nil
    end
  end

  defp map_claims(claims) do
    permissions = permissions_from(claims)
    role = role_from(permissions)
    identity = identity_from(claims)

    Logger.debug("[MCPAuth] authenticated via Auth0 OAuth: role=#{role} identity=#{identity}")

    %{
      role: role,
      org_id: nil,
      permissions: permissions,
      agent_identity: identity,
      allowed_teams: nil,
      allowed_projects: nil
    }
  end

  defp permissions_from(%{"permissions" => perms}) when is_list(perms), do: perms
  defp permissions_from(%{"scope" => scope}) when is_binary(scope), do: String.split(scope, " ", trim: true)
  defp permissions_from(_), do: []

  defp role_from(permissions) when is_list(permissions) do
    cond do
      "mcp:admin" in permissions -> "admin"
      "mcp:tools" in permissions -> "collaborator"
      permissions != [] -> "collaborator"
      true -> "collaborator"
    end
  end

  defp identity_from(%{"email" => email}) when is_binary(email) and email != "", do: email
  defp identity_from(%{"sub" => sub}) when is_binary(sub), do: sub
  defp identity_from(_), do: "oauth-user"
end
