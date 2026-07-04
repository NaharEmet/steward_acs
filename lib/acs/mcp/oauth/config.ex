defmodule Acs.MCP.OAuth.Config do
  @moduledoc """
  Auth0 / OIDC settings for MCP OAuth (Claude Connectors).

  Mirrors ASP.NET `AddJwtBearer` with `Authority` + `Audience`.
  """

  @doc "OAuth Bearer auth is enabled when Auth0 domain and audience are configured."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:steward_acs, :oauth_bearer_enabled, false) == true and
      is_binary(domain()) and domain() != "" and
      is_binary(audience()) and audience() != ""
  end

  @spec domain() :: String.t() | nil
  def domain, do: Application.get_env(:steward_acs, :auth0_domain)

  @spec audience() :: String.t() | nil
  def audience, do: Application.get_env(:steward_acs, :auth0_audience)

  @spec issuer() :: String.t() | nil
  def issuer do
    case Application.get_env(:steward_acs, :auth0_issuer) do
      iss when is_binary(iss) and iss != "" -> String.trim_trailing(iss, "/")
      _ -> domain() && "https://#{String.trim_trailing(domain(), "/")}"
    end
  end

  @spec authorization_server() :: String.t() | nil
  def authorization_server do
    case issuer() do
      nil -> nil
      iss -> iss <> "/"
    end
  end

  @doc "Public MCP resource URL (must match Auth0 API identifier and Claude connector URL)."
  @spec resource_url() :: String.t() | nil
  def resource_url do
    Application.get_env(:steward_acs, :mcp_resource_url) || audience()
  end

  @spec jwks_url() :: String.t() | nil
  def jwks_url do
    case issuer() do
      nil -> nil
      iss -> iss <> "/.well-known/jwks.json"
    end
  end

  @spec protected_resource_metadata_path() :: String.t()
  def protected_resource_metadata_path do
    "/.well-known/oauth-protected-resource/mcp/sse"
  end

  @spec protected_resource_metadata_url() :: String.t() | nil
  def protected_resource_metadata_url do
    case public_base_url() do
      nil -> nil
      base -> base <> protected_resource_metadata_path()
    end
  end

  @spec scopes_supported() :: [String.t()]
  def scopes_supported do
    Application.get_env(:steward_acs, :auth0_scopes, ["mcp:tools"])
  end

  defp public_base_url do
    case Application.get_env(:steward_acs, :mcp_public_url) do
      url when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/")

      _ ->
        case System.get_env("PHX_HOST") do
          host when is_binary(host) and host != "" -> "https://" <> host
          _ -> nil
        end
    end
  end
end
