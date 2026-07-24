defmodule AcsWeb.AccountLandingController do
  @moduledoc """
  Public account-host landing: choose sign-in or create an organization.
  """

  use AcsWeb, :controller

  def index(conn, _params) do
    render_landing(conn)
  end

  @doc false
  def render_landing(conn) do
    conn
    |> put_view(html: AcsWeb.AccountLandingHTML)
    |> put_layout(false)
    |> render(:index,
      self_service_enabled:
        Application.get_env(:steward_acs, :self_service_orgs_enabled, false) == true
    )
  end
end
