defmodule AcsWeb.UserSessionController do
  use AcsWeb, :controller

  require Logger

  alias Acs.Accounts
  alias Acs.Accounts.User
  alias Acs.Orgs
  alias AcsWeb.UserAuth

  def new(conn, _params) do
    unless oidc_config() do
      maybe_warn_default_basic_auth()
    end

    render(conn, :new, layout: false, oidc_enabled: not is_nil(oidc_config()))
  end

  def create(conn, %{"user" => %{"username" => username, "password" => password}}) do
    if oidc_config() do
      conn
      |> put_flash(:error, "Use Auth0 to sign in.")
      |> redirect(to: ~p"/users/log_in")
    else
      config = basic_auth_config()

      if secure_compare(username, config[:username]) and
           secure_compare(password, config[:password]) do
        case local_dashboard_user(conn) do
          {:ok, user} ->
            UserAuth.log_in_user(conn, user)

          {:error, _} ->
            conn
            |> put_flash(:error, "Could not create user.")
            |> redirect(to: ~p"/users/log_in")
        end
      else
        conn
        |> put_flash(:error, "Invalid username or password.")
        |> redirect(to: ~p"/users/log_in")
      end
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "Invalid username or password.")
    |> redirect(to: ~p"/users/log_in")
  end

  def auth_log_in(conn, params) do
    case oidc_config() do
      nil ->
        conn
        |> redirect(to: ~p"/users/log_in")

      config ->
        return_to = return_to(conn, params)
        strategy = Application.get_env(:steward_acs, :oidc_strategy, Assent.Strategy.OIDC)
        config = Keyword.put(config, :nonce, fresh_nonce())

        case strategy.authorize_url(config) do
          {:ok, %{url: url, session_params: session_params}} when is_binary(url) ->
            conn
            |> delete_session(:user_return_to)
            |> put_session(:oidc_session, %{session_params: session_params, return_to: return_to})
            |> redirect(external: url)

          _ ->
            oidc_error(conn)
        end
    end
  end

  def callback(conn, params) do
    session = get_session(conn, :oidc_session)
    conn = delete_session(conn, :oidc_session)

    with config when not is_nil(config) <- oidc_config(),
         %{session_params: session_params} <- session,
         {:ok, %{user: claims}} <-
           Application.get_env(:steward_acs, :oidc_strategy, Assent.Strategy.OIDC).callback(
             Keyword.put(config, :session_params, session_params),
             params
           ),
         {:ok, attrs} <- oidc_user_attrs(claims, Keyword.fetch!(config, :base_url)),
         {:ok, user} <- Accounts.upsert_oidc_user(attrs) do
      complete_sign_in(conn, user, session_return_to(session))
    else
      _ -> oidc_error(conn)
    end
  end

  def handoff_start(conn, %{"token" => token}) when is_binary(token) do
    state = fresh_nonce()

    with host_type when host_type in [:tenant, :account_tenant] <- conn.assigns[:host_type],
         org when is_binary(org) <- conn.assigns[:current_org] do
      conn
      |> put_session(:handoff_state, state)
      |> put_resp_header("referrer-policy", "no-referrer")
      |> redirect(
        external:
          UserAuth.account_url(conn, "/auth/handoff/confirm", %{
            token: token,
            state: state,
            org: org
          })
      )
    else
      _ -> handoff_error(conn)
    end
  end

  def handoff_start(conn, _params), do: handoff_error(conn)

  def handoff_confirm(conn, %{"token" => token, "state" => state, "org" => org}) do
    user = conn.assigns.current_user

    with ^org <- user |> UserAuth.organization_for_user() |> organization_slug(),
         :ok <- Accounts.bind_session_handoff(token, org, user, state),
         url when is_binary(url) <-
           UserAuth.tenant_url(conn, org, "/auth/handoff/complete", %{
             token: token,
             state: state
           }) do
      conn
      |> put_resp_header("referrer-policy", "no-referrer")
      |> redirect(external: url)
    else
      _ -> handoff_error(conn)
    end
  end

  def handoff_confirm(conn, _params), do: handoff_error(conn)

  def handoff_complete(conn, %{"token" => token, "state" => state}) do
    stored_state = get_session(conn, :handoff_state)
    conn = delete_session(conn, :handoff_state)

    with true <- is_binary(stored_state) and Plug.Crypto.secure_compare(stored_state, state),
         host_type when host_type in [:tenant, :account_tenant] <- conn.assigns[:host_type],
         org when is_binary(org) <- conn.assigns[:current_org],
         {:ok, %{user: user, return_to: stored_return_to}} <-
           Accounts.consume_session_handoff(token, org, state) do
      UserAuth.log_in_user(conn, user, redirect_to: safe_return_to(stored_return_to))
    else
      _ -> handoff_error(conn)
    end
  end

  def handoff_complete(conn, _params), do: handoff_error(conn)

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end

  defp complete_sign_in(conn, user, "/invitations/" <> _ = return_to) do
    UserAuth.log_in_user(conn, user, redirect_to: return_to)
  end

  defp complete_sign_in(conn, user, return_to) do
    case UserAuth.organization_for_user(user) do
      org when is_map(org) ->
        cond do
          not UserAuth.organization_ready?(org) ->
            UserAuth.log_in_user(conn, user, redirect_to: "/onboarding")

          # Single-tenant / local: stay on this host. Handoff is for multi-tenant
          # subdomain cookie transfer only.
          not Acs.Org.multi_tenant?() ->
            UserAuth.log_in_user(conn, user, redirect_to: return_to)

          true ->
            handoff_user(conn, user, org, return_to)
        end

      _ ->
        UserAuth.log_in_user(conn, user, redirect_to: "/onboarding")
    end
  end

  defp handoff_user(conn, user, org, return_to) do
    case Accounts.create_session_handoff(user, org, return_to) do
      {:ok, token} when is_binary(token) ->
        conn
        |> UserAuth.put_user_session(user)
        |> redirect_to_handoff(org, token)

      _ ->
        conn
        |> put_flash(:error, "Unable to complete sign in.")
        |> redirect(to: "/onboarding")
    end
  end

  defp redirect_to_handoff(conn, org, token) do
    case UserAuth.tenant_url(conn, org, "/auth/handoff", %{token: token}) do
      url when is_binary(url) ->
        conn
        |> put_resp_header("referrer-policy", "no-referrer")
        |> redirect(external: url)

      _ ->
        conn
        |> put_flash(:error, "Unable to complete sign in.")
        |> redirect(to: "/onboarding")
    end
  end

  defp oidc_config do
    # ponytail: Auth0 dashboard login is multi-tenant only; local uses basic auth.
    if Acs.Org.multi_tenant?() do
      issuer = Application.get_env(:steward_acs, :oidc_issuer)
      client_id = Application.get_env(:steward_acs, :oidc_client_id)
      client_secret = Application.get_env(:steward_acs, :oidc_client_secret)
      redirect_uri = Application.get_env(:steward_acs, :oidc_redirect_uri)

      if Application.get_env(:steward_acs, :oidc_browser_enabled, false) and
           Enum.all?([issuer, client_id, client_secret, redirect_uri], &present?/1) do
        # Optional AUTH0_CONNECTION pin (e.g. email or google-oauth2). When unset,
        # Universal Login offers every connection enabled on the web client.
        # ACS relinks Google vs email OTP by verified email (upsert_oidc_user).
        auth_params =
          case Application.get_env(:steward_acs, :auth0_connection) do
            connection when is_binary(connection) and connection != "" ->
              [scope: "profile email", connection: connection]

            _ ->
              [scope: "profile email"]
          end

        [
          client_id: client_id,
          client_secret: client_secret,
          base_url: issuer,
          redirect_uri: redirect_uri,
          authorization_params: auth_params,
          code_verifier: true
        ]
      end
    end
  end

  defp oidc_user_attrs(claims, issuer) when is_map(claims) do
    with subject when is_binary(subject) and subject != "" <- Map.get(claims, "sub"),
         email when is_binary(email) and email != "" <- Map.get(claims, "email"),
         true <- Map.get(claims, "email_verified") do
      name = Map.get(claims, "name")
      first_name = Map.get(claims, "given_name") || Map.get(claims, "first_name")
      last_name = Map.get(claims, "family_name") || Map.get(claims, "last_name")

      {first_name, last_name} =
        if first_name || last_name do
          {first_name, last_name}
        else
          case name do
            nil -> {nil, nil}
            name when is_binary(name) ->
              case String.split(name, " ", parts: 2) do
                [f, l] -> {f, l}
                [f] -> {f, nil}
                _ -> {nil, nil}
              end
          end
        end

      {:ok,
       %{
         issuer: issuer,
         subject: subject,
         email: email,
         email_verified: true,
         name: name,
         first_name: first_name,
         last_name: last_name
       }}
    else
      _ -> {:error, :invalid_claims}
    end
  end

  defp oidc_user_attrs(_, _), do: {:error, :invalid_claims}

  defp return_to(conn, params) do
    case params["return_to"] || get_session(conn, :user_return_to) do
      path when is_binary(path) -> safe_return_to(path)
      _ -> "/"
    end
  end

  defp session_return_to(%{return_to: return_to}) when is_binary(return_to) do
    if UserAuth.valid_return_to?(return_to), do: return_to, else: "/"
  end

  defp session_return_to(_), do: "/"

  defp safe_return_to(path) do
    if UserAuth.valid_return_to?(path), do: path, else: "/"
  end

  defp handoff_error(conn) do
    conn
    |> put_flash(:error, "Unable to complete sign in.")
    |> redirect(external: UserAuth.account_url(conn, "/users/log_in"))
  end

  defp oidc_error(conn) do
    conn
    |> put_flash(:error, "Sign in is unavailable. Please try again later.")
    |> redirect(to: "/users/log_in")
  end

  defp organization_slug(organization) when is_map(organization) do
    Map.get(organization, :slug) || Map.get(organization, "slug")
  end

  defp organization_slug(_), do: nil

  defp fresh_nonce do
    :crypto.strong_rand_bytes(32)
    |> Base.url_encode64(padding: false)
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp basic_auth_config do
    Application.get_env(:steward_acs, :basic_auth, %{username: "admin", password: "admin"})
  end

  defp maybe_warn_default_basic_auth do
    config = basic_auth_config()

    if config[:username] == "admin" and config[:password] == "admin" do
      Logger.warning(
        "[Auth] Dashboard using default admin/admin credentials — set ACS_USERNAME/ACS_PASSWORD env vars"
      )
    end
  end

  defp local_dashboard_user(conn) do
    slug = conn.assigns[:current_org] || Acs.Org.configured()
    organization = ensure_local_organization!(slug)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    owner_attrs = %{
      organization_id: organization.id,
      org_role: "owner",
      org: organization.slug,
      confirmed_at: now
    }

    case Accounts.get_user_by_email("admin@localhost", organization.slug) do
      %User{} = user ->
        user
        |> User.changeset(Map.put(owner_attrs, :confirmed_at, user.confirmed_at || now))
        |> Acs.Repo.update()

      nil ->
        Accounts.register_user(
          owner_attrs
          |> Map.put(:email, "admin@localhost")
          |> Map.put(:first_name, "Admin")
        )
    end
  end

  defp ensure_local_organization!(slug) when is_binary(slug) do
    case Orgs.get_by_slug(slug) do
      %{id: id} = organization when is_integer(id) ->
        organization

      _ when slug == "default" ->
        Orgs.ensure_default!()

      _ ->
        case Orgs.create(%{name: humanize_slug(slug), slug: slug, subdomain: slug}) do
          {:ok, organization} -> organization
          {:error, _} -> Orgs.ensure_default!()
        end
    end
  end

  defp humanize_slug(slug) do
    slug
    |> String.split(~r/[-_]/)
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and Plug.Crypto.secure_compare(left, right)
  end

  defp secure_compare(_, _), do: false
end
