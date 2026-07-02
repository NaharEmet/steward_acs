defmodule Acs.MCP.Plugs.Strategies.OAuthBearer do
  @moduledoc """
  Placeholder OAuth Bearer token authentication strategy.

  Reads the `Authorization: Bearer <token>` header from the connection.
  Currently returns `{:error, :not_implemented}` — a hook for future
  OAuth/OIDC integration (e.g., Google Workspace, Azure AD, Auth0).

  When implemented, this strategy should:
  - Extract the token from the `Authorization` header
  - Validate the token against an OIDC provider (JWKS key set)
  - Extract claims (sub, email, groups) and map them to role + ABAC attributes
  - Return `{:ok, %{role:, org_id:, permissions:, allowed_teams:, allowed_projects:}}`
  """
  @behaviour Acs.MCP.Plugs.AuthStrategy

  @impl true
  def authenticate(_key, conn) do
    bearer_token = extract_bearer(conn)

    if bearer_token do
      {:error, :not_implemented}
    else
      {:error, "Not a Bearer token"}
    end
  end

  defp extract_bearer(conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> token
      _ -> nil
    end
  end
end
