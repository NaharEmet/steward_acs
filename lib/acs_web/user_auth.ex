defmodule AcsWeb.UserAuth do
  use AcsWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Component, only: [assign_new: 3]
  import Phoenix.Controller

  alias Acs.Accounts

  @session_key :user_token

  def log_in_user(conn, user, opts \\ []) do
    redirect_to = Keyword.get(opts, :redirect_to, "/")

    conn
    |> put_user_session(user)
    |> redirect(to: internal_path(redirect_to))
  end

  def put_user_session(conn, user) do
    token = Accounts.generate_user_session_token(user)

    conn
    |> renew_session()
    |> put_session(@session_key, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
  end

  def log_out_user(conn) do
    user_token = get_session(conn, @session_key)

    case user_token && Accounts.get_user_by_session_token(user_token) do
      %{id: user_id} -> Accounts.revoke_user_auth(user_id)
      _ -> user_token && Accounts.delete_user_session_token(user_token)
    end

    if live_socket_id = get_session(conn, :live_socket_id) do
      AcsWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> redirect(external: account_url(conn, "/users/log_in"))
  end

  def fetch_current_user(conn, _opts) do
    user_token = get_session(conn, @session_key)
    assign(conn, :current_user, user_token && Accounts.get_user_by_session_token(user_token))
  end

  def redirect_if_authenticated(conn, _opts) do
    case conn.assigns[:current_user] do
      nil -> conn
      user -> redirect_authenticated_user(conn, user)
    end
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      login_url =
        if conn.method == "GET" do
          account_url(conn, "/auth/log_in", %{return_to: current_path(conn)})
        else
          account_url(conn, "/auth/log_in")
        end

      conn
      |> maybe_store_return_to()
      |> put_flash(:error, "You must log in to access this page.")
      |> redirect(external: login_url)
      |> halt()
    end
  end

  def require_account_host(conn, _opts) do
    if conn.assigns[:host_type] in [:account, :account_tenant] do
      conn
    else
      conn
      |> redirect(external: account_url(conn, current_path(conn)))
      |> halt()
    end
  end

  def require_tenant_user(conn, _opts) do
    if tenant_user?(conn.assigns[:current_user], conn.assigns[:current_org]) do
      :ok = Acs.Org.put_current(conn.assigns.current_org)
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "not found")
      |> halt()
    end
  end

  def require_org_admin(conn, _opts) do
    if tenant_user?(conn.assigns[:current_user], conn.assigns[:current_org]) and
         organization_role(conn.assigns.current_user) in ["owner", "admin"] do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(403, "forbidden")
      |> halt()
    end
  end

  def fetch_user_token(conn) do
    %{
      "user_token" => get_session(conn, @session_key),
      "current_org" => conn.assigns[:current_org],
      "host_type" => Atom.to_string(conn.assigns[:host_type] || :unknown)
    }
  end

  def on_mount(:assign_org, _params, session, socket) do
    case session["current_org"] do
      org when is_binary(org) and org != "" ->
        :ok = Acs.Org.put_current(org)
        {:cont, Phoenix.Component.assign(socket, :current_org, org)}

      _ ->
        {:cont, socket}
    end
  end

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket =
      assign_new(socket, :current_user, fn ->
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end
      end)

    if socket.assigns.current_user do
      {:cont, subscribe_to_user_disconnect(socket, socket.assigns.current_user)}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/auth/log_in")}
    end
  end

  def on_mount(:ensure_account_host, _params, session, socket) do
    if session["host_type"] in ["account", "account_tenant"] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    end
  end

  def on_mount(:ensure_tenant_member, _params, session, socket) do
    org = session["current_org"] || socket.assigns[:current_org]
    user = socket.assigns[:current_user]

    if tenant_user?(user, org) do
      :ok = Acs.Org.put_current(org)
      {:cont, Phoenix.Component.assign(socket, :current_org, org)}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/auth/log_in")}
    end
  end

  def on_mount(:ensure_org_admin, _params, session, socket) do
    org = session["current_org"] || socket.assigns[:current_org]
    user = socket.assigns[:current_user]

    if tenant_user?(user, org) and organization_role(user) in ["owner", "admin"] do
      {:cont, socket}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    end
  end

  def on_mount(:redirect_if_authenticated, _params, session, socket) do
    socket =
      assign_new(socket, :current_user, fn ->
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end
      end)

    if socket.assigns.current_user do
      {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    else
      {:cont, socket}
    end
  end

  def account_url(conn, path, query \\ %{}) do
    absolute_url(conn, account_host(), path, query)
  end

  def tenant_url(conn, org, path, query \\ %{}) do
    if Acs.Org.multi_tenant?() do
      with label when is_binary(label) <- tenant_label(org),
           true <- Regex.match?(~r/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/, label),
           base when is_binary(base) <- tenant_base_domain(),
           true <- valid_host?(base) do
        absolute_url(conn, label <> "." <> base, path, query)
      else
        _ -> nil
      end
    else
      absolute_url(conn, account_host(), path, query)
    end
  end

  def account_path(path), do: internal_path(path)

  def valid_return_to?(path) when is_binary(path) do
    uri = URI.parse(path)

    String.starts_with?(path, "/") and not String.starts_with?(path, "//") and
      is_nil(uri.scheme) and is_nil(uri.host) and is_nil(uri.userinfo) and
      not String.contains?(path, ["\\", "\r", "\n"])
  end

  def valid_return_to?(_), do: false

  def organization_for_user(user), do: Accounts.organization_for_user(user)

  def organization_ready?(org) when is_map(org) do
    case Map.get(org, :id) || Map.get(org, "id") do
      id when is_integer(id) ->
        (Map.get(org, :provisioning_status) || Map.get(org, "provisioning_status")) == "ready"

      _ ->
        true
    end
  end

  def organization_ready?(_), do: false

  defp redirect_authenticated_user(conn, user) do
    case conn.assigns[:host_type] do
      host_type when host_type in [:tenant, :account_tenant] ->
        conn
        |> redirect(to: "/")
        |> halt()

      :account ->
        case organization_for_user(user) do
          org when is_map(org) ->
            redirect_with_handoff(conn, user, org)

          _ ->
            conn
            |> redirect(to: "/onboarding")
            |> halt()
        end

      _ ->
        conn
        |> redirect(to: "/")
        |> halt()
    end
  end

  defp redirect_with_handoff(conn, user, org) do
    if organization_ready?(org) do
      return_to = stored_return_to(conn)

      case Accounts.create_session_handoff(user, org, return_to) do
        {:ok, token} when is_binary(token) ->
          case tenant_url(conn, org, "/auth/handoff", %{token: token}) do
            url when is_binary(url) ->
              conn
              |> delete_session(:user_return_to)
              |> put_resp_header("referrer-policy", "no-referrer")
              |> redirect(external: url)
              |> halt()

            _ ->
              conn
              |> redirect(to: "/onboarding")
              |> halt()
          end

        _ ->
          conn
          |> redirect(to: "/onboarding")
          |> halt()
      end
    else
      conn
      |> redirect(to: "/onboarding")
      |> halt()
    end
  end

  defp tenant_user?(user, slug) when is_map(user) and is_binary(slug) do
    with organization when is_map(organization) <- organization_for_user(user),
         ^slug <- Map.get(organization, :slug) || Map.get(organization, "slug"),
         true <- organization_ready?(organization) do
      true
    else
      _ -> false
    end
  end

  defp tenant_user?(_, _), do: false

  defp organization_role(user) when is_map(user) do
    Map.get(user, :org_role) || Map.get(user, "org_role") || Map.get(user, :role) ||
      Map.get(user, "role")
  end

  defp organization_role(_), do: nil

  defp subscribe_to_user_disconnect(socket, %{id: user_id}) do
    topic = "users:#{user_id}"

    if Phoenix.LiveView.connected?(socket) do
      AcsWeb.Endpoint.subscribe(topic)
    end

    Phoenix.LiveView.attach_hook(socket, :user_disconnect, :handle_info, fn
      %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}, socket ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/users/log_in")}

      _message, socket ->
        {:cont, socket}
    end)
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  defp stored_return_to(conn) do
    case get_session(conn, :user_return_to) do
      path when is_binary(path) -> internal_path(path)
      _ -> "/"
    end
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  defp internal_path(path) when is_binary(path) do
    if valid_return_to?(path), do: path, else: "/"
  end

  defp internal_path(_), do: "/"

  defp account_host do
    case Application.get_env(:steward_acs, :account_host, "localhost") do
      host when is_binary(host) ->
        if valid_host?(host), do: String.downcase(host), else: "localhost"

      _ ->
        "localhost"
    end
  end

  defp tenant_label(org) when is_map(org) do
    Map.get(org, :subdomain) || Map.get(org, "subdomain") || Map.get(org, :slug) ||
      Map.get(org, "slug")
  end

  defp tenant_label(slug) when is_binary(slug), do: slug
  defp tenant_label(_), do: nil

  defp tenant_base_domain do
    Application.get_env(:steward_acs, :base_domain) || account_host()
  end

  defp absolute_url(conn, host, path, query) do
    endpoint_url = Application.get_env(:steward_acs, AcsWeb.Endpoint, []) |> Keyword.get(:url, [])
    scheme = Keyword.get(endpoint_url, :scheme) || to_string(conn.scheme || :http)
    port = Keyword.get(endpoint_url, :port) || conn.port

    %URI{
      scheme: to_string(scheme),
      host: host,
      port: normalize_port(port, scheme),
      path: internal_path(path),
      query: if(query == %{}, do: nil, else: URI.encode_query(query))
    }
    |> URI.to_string()
  end

  defp normalize_port(port, scheme) when scheme in ["https", :https] and port == 443, do: nil
  defp normalize_port(port, scheme) when scheme in ["http", :http] and port == 80, do: nil
  defp normalize_port(port, _scheme), do: port

  defp valid_host?(host) do
    Regex.match?(~r/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/, String.downcase(host))
  end
end
