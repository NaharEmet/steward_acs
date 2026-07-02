defmodule AcsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :steward_acs

  @session_options [
    store: :cookie,
    key: "_acs_web_key",
    signing_salt: Application.get_env(:steward_acs, :session_signing_salt, "acs_cookie_session_v1"),
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :steward_acs,
    gzip: true,
    only: AcsWeb.static_paths()

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  plug CORSPlug

  plug :route_mcp_or_dashboard

  defp route_mcp_or_dashboard(conn, _opts) do
    if String.starts_with?(conn.request_path, "/mcp") or
         String.starts_with?(conn.request_path, "/api") do
      Acs.MCP.HTTPServer.call(conn, [])
    else
      AcsWeb.Router.call(conn, [])
    end
  end
end
