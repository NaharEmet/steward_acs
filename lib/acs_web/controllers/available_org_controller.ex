defmodule AcsWeb.AvailableOrgController do
  @moduledoc """
  Public landing for tenant hosts whose subdomain is not yet claimed.
  Rendered from `AcsWeb.Plugs.ResolveOrg` (before the router).
  """

  use AcsWeb, :controller

  alias AcsWeb.UserAuth

  @doc false
  def render_available(conn, subdomain) when is_binary(subdomain) do
    self_service = Application.get_env(:steward_acs, :self_service_orgs_enabled, false) == true
    return_to = "/onboarding?subdomain=#{URI.encode_www_form(subdomain)}"

    create_url =
      if self_service do
        UserAuth.account_url(conn, "/users/log_in", %{"return_to" => return_to})
      else
        UserAuth.account_url(conn, "/")
      end

    conn
    |> fetch_query_params()
    |> put_format("html")
    |> put_root_layout(html: {AcsWeb.Layouts, :root})
    |> put_layout(false)
    |> put_view(html: AcsWeb.AvailableOrgHTML)
    |> put_status(200)
    |> render(:show,
      subdomain: subdomain,
      host: conn.host,
      self_service_enabled: self_service,
      create_url: create_url,
      sign_in_url: UserAuth.account_url(conn, "/users/log_in")
    )
  end
end
