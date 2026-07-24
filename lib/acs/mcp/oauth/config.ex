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
  def authorization_server, do: authorization_server(nil)

  @doc """
  Authorization server identifier advertised in protected-resource metadata.

  In multi-tenant mode this is the request host (Caddy proxies /authorize,/token
  and injects the per-host Auth0 audience). Otherwise Auth0's issuer.
  """
  @spec authorization_server(Plug.Conn.t() | nil) :: String.t() | nil
  def authorization_server(%Plug.Conn{} = conn) do
    if host_aware_oauth?(conn) do
      "https://#{conn.host}/"
    else
      authorization_server(nil)
    end
  end

  def authorization_server(nil) do
    case issuer() do
      nil -> nil
      iss -> iss <> "/"
    end
  end

  @doc "Public MCP resource URL (must match Auth0 API identifier and Claude connector URL)."
  @spec resource_url() :: String.t() | nil
  def resource_url, do: resource_url(nil)

  @spec resource_url(Plug.Conn.t() | nil) :: String.t() | nil
  def resource_url(%Plug.Conn{} = conn) do
    if host_aware_oauth?(conn) do
      resource_url_for_host(conn.host)
    else
      legacy_resource_url()
    end
  end

  def resource_url(nil), do: legacy_resource_url()

  @doc "Auth0 API audience for JWT validation on this request."
  @spec audience_for_conn(Plug.Conn.t()) :: String.t() | nil
  def audience_for_conn(%Plug.Conn{host: host}) do
    if host_aware_oauth?(%Plug.Conn{host: host}) do
      resource_url_for_host(host)
    else
      audience()
    end
  end

  @spec resource_url_for_host(String.t()) :: String.t()
  def resource_url_for_host(host) when is_binary(host) do
    "https://#{host}/mcp/sse"
  end

  defp legacy_resource_url do
    Application.get_env(:steward_acs, :mcp_resource_url) || audience()
  end

  defp host_aware_oauth?(%Plug.Conn{host: host}) do
    Acs.Org.multi_tenant?() and is_binary(host) and host != ""
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
  def protected_resource_metadata_url, do: protected_resource_metadata_url(nil)

  @spec protected_resource_metadata_url(Plug.Conn.t() | nil) :: String.t() | nil
  def protected_resource_metadata_url(%Plug.Conn{} = conn) do
    case public_base_url(conn) do
      nil -> nil
      base -> base <> protected_resource_metadata_path()
    end
  end

  def protected_resource_metadata_url(nil) do
    case public_base_url(nil) do
      nil -> nil
      base -> base <> protected_resource_metadata_path()
    end
  end

  @spec scopes_supported() :: [String.t()]
  def scopes_supported do
    Application.get_env(:steward_acs, :auth0_scopes, ["mcp:tools"])
  end

  @doc """
  Fixed Auth0 application client_id returned from `/oidc/register`.
  Prevents Claude DCR from creating a new third-party app on every connect.
  """
  @spec fixed_dcr_client_id() :: String.t() | nil
  def fixed_dcr_client_id do
    case Application.get_env(:steward_acs, :oauth_fixed_dcr_client_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp public_base_url(%Plug.Conn{} = conn) do
    if host_aware_oauth?(conn), do: "https://#{conn.host}", else: public_base_url(nil)
  end

  defp public_base_url(nil) do
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
