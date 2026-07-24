defmodule AcsWeb.UserSessionController do
  use AcsWeb, :controller

  alias Acs.Accounts
  alias AcsWeb.UserAuth

  def new(conn, _params) do
    render(conn, :new, layout: false, oidc_enabled: not is_nil(oidc_config()))
  end

  def auth_log_in(conn, params) do
    case oidc_config() do
      nil ->
        oidc_error(conn)

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
        if UserAuth.organization_ready?(org) do
          handoff_user(conn, user, org, return_to)
        else
          UserAuth.log_in_user(conn, user, redirect_to: "/onboarding")
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
    issuer = Application.get_env(:steward_acs, :oidc_issuer)
    client_id = Application.get_env(:steward_acs, :oidc_client_id)
    client_secret = Application.get_env(:steward_acs, :oidc_client_secret)
    redirect_uri = Application.get_env(:steward_acs, :oidc_redirect_uri)

    if Application.get_env(:steward_acs, :oidc_browser_enabled, false) and
         Enum.all?([issuer, client_id, client_secret, redirect_uri], &present?/1) do
      [
        client_id: client_id,
        client_secret: client_secret,
        base_url: issuer,
        redirect_uri: redirect_uri,
        authorization_params: [scope: "profile email"],
        code_verifier: true
      ]
    end
  end

  defp oidc_user_attrs(claims, issuer) when is_map(claims) do
    with subject when is_binary(subject) and subject != "" <- Map.get(claims, "sub"),
         email when is_binary(email) and email != "" <- Map.get(claims, "email"),
         true <- Map.get(claims, "email_verified") do
      {:ok,
       %{
         issuer: issuer,
         subject: subject,
         email: email,
         email_verified: true,
         name: Map.get(claims, "name")
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
end
