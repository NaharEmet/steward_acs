defmodule AcsWeb.UserSessionControllerTest do
  use AcsWeb.ConnCase, async: false

  alias Acs.Accounts

  defmodule OIDCStrategy do
    def authorize_url(config) do
      nonce = Keyword.fetch!(config, :nonce)
      true = is_binary(nonce) and byte_size(nonce) >= 32

      {:ok,
       %{
         url: "https://auth.example.test/authorize?state=provider-state",
         session_params: %{state: "provider-state", nonce: "provider-nonce"}
       }}
    end

    def callback(_config, %{"code" => "verified"}) do
      {:ok,
       %{
         user: %{
           "sub" => "auth0|verified-user",
           "email" => "verified@example.test",
           "email_verified" => true,
           "name" => "Verified User"
         }
       }}
    end

    def callback(_config, %{"code" => "unverified"}) do
      {:ok,
       %{
         user: %{
           "sub" => "auth0|unverified-user",
           "email" => "unverified@example.test",
           "email_verified" => false
         }
       }}
    end
  end

  setup do
    previous =
      for key <- [
            :oidc_browser_enabled,
            :oidc_issuer,
            :oidc_client_id,
            :oidc_client_secret,
            :oidc_redirect_uri,
            :oidc_strategy,
            :account_host,
            :multi_tenant
          ],
          into: %{},
          do: {key, Application.get_env(:steward_acs, key)}

    Application.put_env(:steward_acs, :oidc_browser_enabled, true)
    Application.put_env(:steward_acs, :oidc_issuer, "https://issuer.example.test/")
    Application.put_env(:steward_acs, :oidc_client_id, "client-id")
    Application.put_env(:steward_acs, :oidc_client_secret, "client-secret")
    Application.put_env(:steward_acs, :oidc_redirect_uri, "http://localhost/auth/callback")
    Application.put_env(:steward_acs, :oidc_strategy, OIDCStrategy)
    Application.put_env(:steward_acs, :account_host, "localhost")
    Application.put_env(:steward_acs, :multi_tenant, false)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:steward_acs, key)
        {key, value} -> Application.put_env(:steward_acs, key, value)
      end)
    end)

    :ok
  end

  test "starts OIDC authorization and stores provider session parameters", %{conn: conn} do
    conn = get(conn, "/auth/log_in", %{"return_to" => "/onboarding"})

    assert redirected_to(conn) ==
             "https://auth.example.test/authorize?state=provider-state"

    assert %{session_params: %{state: "provider-state"}, return_to: "/onboarding"} =
             get_session(conn, :oidc_session)
  end

  test "callback creates a global verified identity and redirects an orgless user", %{conn: conn} do
    conn = get(conn, "/auth/log_in")
    conn = conn |> recycle() |> get("/auth/callback", %{"code" => "verified"})

    assert redirected_to(conn) == "/onboarding"
    assert is_binary(get_session(conn, :user_token))

    user =
      Accounts.get_user_by_oidc_identity("https://issuer.example.test/", "auth0|verified-user")

    assert user.email == "verified@example.test"
    assert user.confirmed_at
    assert is_nil(user.organization_id)
  end

  test "callback rejects an identity whose provider email is not verified", %{conn: conn} do
    conn = get(conn, "/auth/log_in")
    conn = conn |> recycle() |> get("/auth/callback", %{"code" => "unverified"})

    assert redirected_to(conn) == "/users/log_in"

    refute Accounts.get_user_by_oidc_identity(
             "https://issuer.example.test/",
             "auth0|unverified-user"
           )
  end
end
