defmodule AcsWeb.Plugs.LocalhostOnly do
  @moduledoc """
  Restricts a route to loopback clients only.

  Used for dev-only utilities such as one-click dev login.
  """
  import Plug.Conn

  @loopback_ips [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.remote_ip in @loopback_ips do
      conn
    else
      conn
      |> send_resp(403, "Forbidden")
      |> halt()
    end
  end
end
