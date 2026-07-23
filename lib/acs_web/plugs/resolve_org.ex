defmodule AcsWeb.Plugs.ResolveOrg do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    :ok = Acs.Org.clear_request_org()

    if Acs.Org.multi_tenant?() do
      resolve_multitenant_host(conn)
    else
      assign_account_tenant(conn, Acs.Org.configured())
    end
  end

  defp resolve_multitenant_host(conn) do
    if account_host?(conn.host) do
      assign(conn, :host_type, :account)
    else
      case Acs.Org.extract_subdomain(conn.host) do
        subdomain when is_binary(subdomain) ->
          case Acs.Orgs.get_by_subdomain(subdomain) do
            nil ->
              unknown_host(conn)

            org ->
              case org_slug(org) do
                slug when is_binary(slug) and slug != "" -> assign_tenant(conn, slug)
                _ -> unknown_host(conn)
              end
          end

        _ ->
          unknown_host(conn)
      end
    end
  end

  defp assign_tenant(conn, slug) do
    :ok = Acs.Org.put_current(slug)

    conn
    |> assign(:host_type, :tenant)
    |> assign(:current_org, slug)
  end

  defp assign_account_tenant(conn, slug) do
    :ok = Acs.Org.put_current(slug)

    conn
    |> assign(:host_type, :account_tenant)
    |> assign(:current_org, slug)
  end

  defp unknown_host(conn) do
    conn
    |> assign(:host_type, :unknown)
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "unknown org")
    |> halt()
  end

  defp account_host?(host) when is_binary(host) do
    case Application.get_env(:steward_acs, :account_host, "localhost") do
      account_host when is_binary(account_host) ->
        String.downcase(host) == String.downcase(account_host)

      _ ->
        false
    end
  end

  defp org_slug(slug) when is_binary(slug), do: slug
  defp org_slug(org) when is_map(org), do: Map.get(org, :slug) || Map.get(org, "slug")
  defp org_slug(_), do: nil
end
