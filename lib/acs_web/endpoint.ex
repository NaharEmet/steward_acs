defmodule AcsWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :steward_acs

  import Plug.Conn

  @max_body_length 2_000_000

  @session_options [
    store: :cookie,
    key: "_acs_web_key",
    signing_salt: "acs_cookie_v1",
    http_only: true,
    secure: Application.compile_env(:steward_acs, :secure_session_cookie, false),
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

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
    pass: ["application/json", "application/x-www-form-urlencoded", "multipart/form-data"],
    length: @max_body_length,
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  plug CORSPlug

  plug :put_security_headers

  plug AcsWeb.Plugs.ResolveOrg

  plug :route_mcp_or_dashboard

  defp put_security_headers(conn, _opts) do
    conn =
      conn
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("x-frame-options", "DENY")
      |> put_resp_header("x-permitted-cross-domain-policies", "none")
      |> put_resp_header("referrer-policy", "no-referrer")
      |> put_resp_header(
        "content-security-policy",
        "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self' ws: wss:; frame-ancestors 'none'; base-uri 'self'"
      )

    conn =
      if String.starts_with?(conn.request_path, ["/auth/", "/invitations/"]) do
        put_resp_header(conn, "cache-control", "no-store")
      else
        conn
      end

    if Application.get_env(:steward_acs, :hsts, false) do
      put_resp_header(conn, "strict-transport-security", "max-age=31536000; includeSubDomains")
    else
      conn
    end
  end

  defp route_mcp_or_dashboard(conn, _opts) do
    cond do
      String.starts_with?(conn.request_path, "/.well-known/oauth-protected-resource") ->
        Acs.MCP.OAuth.WellKnown.call(conn, [])

      String.starts_with?(conn.request_path, "/mcp") or
          String.starts_with?(conn.request_path, "/api") ->
        Acs.MCP.HTTPServer.call(conn, [])

      true ->
        AcsWeb.Router.call(conn, [])
    end
  end
end
