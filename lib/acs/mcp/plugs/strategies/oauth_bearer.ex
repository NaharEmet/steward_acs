defmodule Acs.MCP.Plugs.Strategies.OAuthBearer do
  @moduledoc """
  Auth0 / OIDC Bearer token authentication for MCP OAuth (Claude Connectors).

  Validates JWT access tokens against the Auth0 JWKS endpoint and returns
  validated identity claims and token permissions. `MCPAuth` resolves the local
  ACS role and organization. Equivalent to ASP.NET `AddJwtBearer` with
  `Authority` + `Audience`.
  """
  @behaviour Acs.MCP.Plugs.AuthStrategy

  alias Acs.MCP.OAuth.{Config, JWKS}

  require Logger

  @impl true
  def authenticate(_key, conn) do
    with true <- Config.enabled?(),
         token when is_binary(token) <- bearer_token(conn),
         {:ok, claims} <- JWKS.verify(token, audience: Config.audience_for_conn(conn)),
         {:ok, _issuer, _subject} <- oidc_identity(claims) do
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
    issuer = string_claim(claims, "iss")
    subject = string_claim(claims, "sub")
    email = string_claim(claims, "email")
    identity = identity_from(email, subject)

    Logger.debug("[MCPAuth] authenticated via Auth0 OAuth: identity=#{identity}")

    %{
      role: "collaborator",
      org_id: nil,
      permissions: permissions,
      agent_identity: identity,
      oidc_issuer: issuer,
      oidc_subject: subject,
      email: email,
      allowed_teams: nil,
      allowed_projects: nil
    }
  end

  defp permissions_from(claims) do
    permissions = if is_list(claims["permissions"]), do: claims["permissions"], else: []

    scopes =
      if is_binary(claims["scope"]), do: String.split(claims["scope"], " ", trim: true), else: []

    Enum.uniq(permissions ++ scopes)
  end

  defp oidc_identity(claims) do
    with issuer when is_binary(issuer) and issuer != "" <- string_claim(claims, "iss"),
         subject when is_binary(subject) and subject != "" <- string_claim(claims, "sub") do
      {:ok, issuer, subject}
    else
      _ -> {:error, "JWT missing subject"}
    end
  end

  defp string_claim(claims, claim) when is_map(claims) do
    case Map.get(claims, claim) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp identity_from(email, _subject) when is_binary(email) and email != "", do: email
  defp identity_from(_email, subject) when is_binary(subject) and subject != "", do: subject
  defp identity_from(_, _), do: "oauth-user"
end
