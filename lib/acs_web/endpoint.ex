defmodule AcsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :steward_acs

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [:user_agent]]

  # Serve static assets from priv/static
  plug Plug.Static,
    at: "/",
    from: :steward_acs,
    gzip: true,
    only: ~w(assets)

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
