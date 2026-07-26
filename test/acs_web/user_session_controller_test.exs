defmodule AcsWeb.UserSessionControllerTest do
  use AcsWeb.ConnCase, async: false

  alias Acs.Accounts

  defmodule OIDCStrategy do
    def authorize_url(config) do
      nonce = Keyword.fetch!(config, :nonce)
      true = is_binary(nonce) and byte_size(nonce) >= 32

      params = Keyword.get(config, :authorization_params, [])
      connection = Keyword.get(params, :connection)
      true = connection in [nil, "email"] or is_binary(connection)

      {:ok,
       %{
         url:
           "https://auth.example.test/authorize?state=provider-state&connection=#{connection || ""}",
         session_params: %{
           state: "provider-state",
           nonce: "provider-nonce",
           connection: connection
         }
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
            :multi_tenant,
            :basic_auth,
            :org_name
          ],
          into: %{},
          do: {key, Application.get_env(:steward_acs, key)}

    Application.put_env(:steward_acs, :account_host, "localhost")
    Application.put_env(:steward_acs, :org_name, "default")
    Application.put_env(:steward_acs, :basic_auth, username: "admin", password: "secret")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:steward_acs, key)
        {key, value} -> Application.put_env(:steward_acs, key, value)
      end)
    end)

    :ok
  end

  describe "single-tenant password login" do
    setup do
      Application.put_env(:steward_acs, :multi_tenant, false)
      Application.put_env(:steward_acs, :oidc_browser_enabled, false)
      :ok
    end

    test "login form shows username and password fields", %{conn: conn} do
      conn = get(conn, "/users/log_in")

      assert html_response(conn, 200) =~ "user[username]"
      assert html_response(conn, 200) =~ "user[password]"
      refute html_response(conn, 200) =~ "Continue with Auth0"
    end

    test "auth_log_in redirects to password form when OIDC is off", %{conn: conn} do
      conn = get(conn, "/auth/log_in")
      assert redirected_to(conn) == "/users/log_in"
    end

    test "valid credentials create a local owner session", %{conn: conn} do
      conn =
        post(conn, "/users/log_in", %{
          "user" => %{"username" => "admin", "password" => "secret"}
        })

      assert redirected_to(conn) == "/"
      assert is_binary(get_session(conn, :user_token))

      user = Accounts.get_user_by_email("admin@localhost", "default")
      assert user.org_role == "owner"
      assert is_integer(user.organization_id)
    end

    test "invalid credentials are rejected", %{conn: conn} do
      conn =
        post(conn, "/users/log_in", %{
          "user" => %{"username" => "admin", "password" => "wrong"}
        })

      assert redirected_to(conn) == "/users/log_in"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid"
      refute get_session(conn, :user_token)
    end
  end

  describe "multi-tenant OIDC login" do
    setup do
      Application.put_env(:steward_acs, :multi_tenant, true)
      Application.put_env(:steward_acs, :oidc_browser_enabled, true)
      Application.put_env(:steward_acs, :oidc_issuer, "https://issuer.example.test/")
      Application.put_env(:steward_acs, :oidc_client_id, "client-id")
      Application.put_env(:steward_acs, :oidc_client_secret, "client-secret")
      Application.put_env(:steward_acs, :oidc_redirect_uri, "http://localhost/auth/callback")
      Application.put_env(:steward_acs, :oidc_strategy, OIDCStrategy)
      :ok
    end

    defp account_conn(conn) do
      Map.put(conn, :host, "localhost")
    end

    test "starts OIDC authorization with email connection and stores provider session parameters",
         %{conn: conn} do
      Application.put_env(:steward_acs, :auth0_connection, "email")

      conn = get(account_conn(conn), "/auth/log_in", %{"return_to" => "/onboarding"})

      assert redirected_to(conn) ==
               "https://auth.example.test/authorize?state=provider-state&connection=email"

      assert %{
               session_params: %{state: "provider-state", connection: "email"},
               return_to: "/onboarding"
             } = get_session(conn, :oidc_session)
    end

    test "callback creates a global verified identity and redirects an orgless user", %{conn: conn} do
      conn = get(account_conn(conn), "/auth/log_in")
      conn = conn |> recycle() |> account_conn() |> get("/auth/callback", %{"code" => "verified"})

      assert redirected_to(conn) == "/onboarding"
      assert is_binary(get_session(conn, :user_token))

      user =
        Accounts.get_user_by_oidc_identity("https://issuer.example.test/", "auth0|verified-user")

      assert user.email == "verified@example.test"
      assert user.confirmed_at
      assert is_nil(user.organization_id)
    end

    test "callback rejects an identity whose provider email is not verified", %{conn: conn} do
      conn = get(account_conn(conn), "/auth/log_in")
      conn = conn |> recycle() |> account_conn() |> get("/auth/callback", %{"code" => "unverified"})

      assert redirected_to(conn) == "/users/log_in"

      refute Accounts.get_user_by_oidc_identity(
               "https://issuer.example.test/",
               "auth0|unverified-user"
             )
    end
  end
end
