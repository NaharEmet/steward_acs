defmodule AcsWeb.Plugs.ResolveOrg do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    subdomain = extract_subdomain(conn)
    org = Acs.Org.from_subdomain(subdomain)
    :ok = Acs.Org.put_current(org)
    assign(conn, :current_org, org)
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
