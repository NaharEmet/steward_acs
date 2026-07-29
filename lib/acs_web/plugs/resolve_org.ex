defmodule AcsWeb.Plugs.ResolveOrg do
  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    :ok = Acs.Org.clear_request_org()

    cond do
      # Container / LB probes hit Host: localhost with no tenant subdomain.
      health_check?(conn) ->
        assign_account_tenant(conn, Acs.Org.configured())

      Acs.Org.multi_tenant?() ->
        resolve_multitenant_host(conn)

      true ->
        assign_account_tenant(conn, Acs.Org.configured())
    end
  end

  defp health_check?(%{method: "GET", request_path: "/mcp/health"}), do: true
  defp health_check?(_), do: false

  defp resolve_multitenant_host(conn) do
    if account_host?(conn.host) do
      resolve_account_host(conn)
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

  # Apex marketing site stays separate (Astro). ACCOUNT_HOST is the ACS app host
  # (prod.stewardacs.xyz): onboarding + login live there. If that host is also a
  # known org subdomain, keep the org scope for MCP/dashboard (:account_tenant).
  defp resolve_account_host(conn) do
    case Acs.Org.extract_subdomain(conn.host) do
      subdomain when is_binary(subdomain) ->
        case Acs.Orgs.get_by_subdomain(subdomain) do
          nil ->
            assign(conn, :host_type, :account)

          org ->
            case org_slug(org) do
              slug when is_binary(slug) and slug != "" -> assign_account_tenant(conn, slug)
              _ -> assign(conn, :host_type, :account)
            end
        end

      _ ->
        assign(conn, :host_type, :account)
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

  # Scanner noise (www/m/portal/…) is expected — 404 is enough. Keep WARN for
  # hosts that look like a real org slug so misconfigured tenants stay visible.
  @noise_hosts ~w(www m portal erp members internal mail smtp ftp api cdn staging test)

  defp unknown_host(conn) do
    meta = [
      action: "org_resolve",
      status: "404",
      error_type: "unknown_host",
      org: conn.host
    ]

    if noise_host?(conn.host) do
      Logger.debug("unknown org host", meta)
    else
      Logger.warning("unknown org host", meta)
    end

    conn
    |> assign(:host_type, :unknown)
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "unknown org")
    |> halt()
  end

  defp noise_host?(host) when is_binary(host) do
    case Acs.Org.extract_subdomain(host) do
      sub when is_binary(sub) -> String.downcase(sub) in @noise_hosts
      _ -> true
    end
  end

  defp noise_host?(_), do: true

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
