defmodule AcsWeb.AccountLandingControllerTest do
  use AcsWeb.ConnCase, async: false

  setup do
    previous =
      for key <- [:account_host, :multi_tenant, :self_service_orgs_enabled, :base_domain],
          into: %{},
          do: {key, Application.get_env(:steward_acs, key)}

    Application.put_env(:steward_acs, :account_host, "account.example.test")
    Application.put_env(:steward_acs, :base_domain, "example.test")
    Application.put_env(:steward_acs, :multi_tenant, true)
    Application.put_env(:steward_acs, :self_service_orgs_enabled, true)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:steward_acs, key)
        {key, value} -> Application.put_env(:steward_acs, key, value)
      end)
    end)

    :ok
  end

  test "account host root shows landing with sign-in and create-org actions", %{conn: conn} do
    conn =
      conn
      |> Map.put(:host, "account.example.test")
      |> get("/")

    assert html_response(conn, 200) =~ "Steward"
    assert html_response(conn, 200) =~ "Sign in"
    assert html_response(conn, 200) =~ "Create an organization"
    assert html_response(conn, 200) =~ ~r{/users/log_in\?[^"]*return_to=}
  end

  test "account host protected paths send anonymous users to the landing", %{conn: conn} do
    conn =
      conn
      |> Map.put(:host, "account.example.test")
      |> get("/onboarding")

    assert redirected_to(conn) == "/"
  end

  test "hides create-org when self-service is disabled", %{conn: conn} do
    Application.put_env(:steward_acs, :self_service_orgs_enabled, false)

    conn =
      conn
      |> Map.put(:host, "account.example.test")
      |> get("/")

    assert html_response(conn, 200) =~ "Sign in"
    refute html_response(conn, 200) =~ "Create an organization"
    assert html_response(conn, 200) =~ "invite-only"
  end
end
