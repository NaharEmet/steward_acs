defmodule AcsWeb.Router do
  use AcsWeb, :router

  import AcsWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AcsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug AcsWeb.Plugs.ResolveOrg
    plug :fetch_current_user
  end

  pipeline :require_auth do
    plug :require_authenticated_user
  end

  pipeline :localhost_only do
    plug AcsWeb.Plugs.LocalhostOnly
  end

  scope "/", AcsWeb do
    pipe_through [:browser, :redirect_if_authenticated]

    get "/users/log_in", UserSessionController, :new
    post "/users/log_in", UserSessionController, :create
  end

  scope "/", AcsWeb do
    pipe_through :browser

    delete "/users/log_out", UserSessionController, :delete
  end

  scope "/", AcsWeb do
    pipe_through [:browser, :require_auth]

    live_session :acs,
      session: {AcsWeb.UserAuth, :fetch_user_token, []},
      on_mount: [{AcsWeb.UserAuth, :ensure_authenticated}] do
      live "/", AcsLive.Index, :index
      live "/tools", AcsLive.Tools, :index
      live "/tools/requests", AcsLive.ToolRequests, :index
      live "/memories", AcsLive.MemoryLive, :index
      live "/specs", AcsLive.SpecsLive, :index
      live "/skills", AcsLive.SkillsLive, :index
      live "/error-traces", AcsLive.ErrorTracesLive, :index
    end
  end

  if Application.compile_env(:steward_acs, :dev_routes, false) do
    scope "/dev" do
      pipe_through [:browser, :localhost_only]
    end
  end

  defp redirect_if_authenticated(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
      |> Phoenix.Controller.redirect(to: "/")
      |> halt()
    else
      conn
    end
  end
end
