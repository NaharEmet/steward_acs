defmodule AcsWeb.Plugs.ResolveOrg do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    subdomain = extract_subdomain(conn)
    org = Acs.Org.from_subdomain(subdomain)

    case org do
      nil ->
        conn |> put_resp_content_type("text/plain") |> send_resp(404, "unknown org") |> halt()

      org ->
        :ok = Acs.Org.put_current(org)
        assign(conn, :current_org, org)
    end
  end

  defp extract_subdomain(conn) do
    host = conn.host
    parts = String.split(host, ".")

    case parts do
      [subdomain | _] when subdomain not in ["www", ""] and length(parts) > 2 ->
        subdomain

      _ ->
        nil
    end
  end
end
