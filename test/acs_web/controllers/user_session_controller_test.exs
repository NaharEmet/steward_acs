defmodule AcsWeb.UserSessionControllerTest do
  use Acs.DataCase, async: false

  import Phoenix.ConnTest

  @endpoint AcsWeb.Endpoint

  setup do
    original_basic = Application.get_env(:steward_acs, :basic_auth)
    original_by_org = Application.get_env(:steward_acs, :basic_auth_by_org)
    original_org = Application.get_env(:steward_acs, :org_name)
    original_domain = Application.get_env(:steward_acs, :base_domain)

    Application.put_env(:steward_acs, :basic_auth, %{
      username: "default-admin",
      password: "default-secret"
    })

    Application.put_env(:steward_acs, :basic_auth_by_org, %{
      "acme" => %{username: "acme-admin", password: "acme-secret"}
    })

    Application.put_env(:steward_acs, :org_name, "default")
    Application.put_env(:steward_acs, :base_domain, "stewardacs.xyz")

    on_exit(fn ->
      restore_env(:basic_auth, original_basic)
      restore_env(:basic_auth_by_org, original_by_org)
      restore_env(:org_name, original_org)
      restore_env(:base_domain, original_domain)
      Acs.Org.clear_request_org()
    end)

    :ok
  end

  test "neutral-host login stores org selected by authenticated credentials" do
    conn =
      build_conn()
      |> Map.put(:host, "stewardacs.xyz")
      |> post("/users/log_in", %{
        "user" => %{"username" => "acme-admin", "password" => "acme-secret"}
      })

    assert redirected_to(conn) == "/"
    assert Plug.Conn.get_session(conn, :current_org) == "acme"
    assert Acs.Accounts.get_user_by_email("admin@localhost", "acme")
  end

  test "neutral-host login rejects credentials shared by multiple orgs" do
    Application.put_env(:steward_acs, :basic_auth_by_org, %{
      "acme" => %{username: "shared", password: "shared-secret"},
      "other" => %{username: "shared", password: "shared-secret"}
    })

    conn =
      build_conn()
      |> Map.put(:host, "stewardacs.xyz")
      |> post("/users/log_in", %{
        "user" => %{"username" => "shared", "password" => "shared-secret"}
      })

    assert redirected_to(conn) == "/users/log_in"
    refute Acs.Accounts.get_user_by_email("admin@localhost", "acme")
    refute Acs.Accounts.get_user_by_email("admin@localhost", "other")
  end

  test "login rejects credentials that mismatch a host hint" do
    conn =
      build_conn()
      |> Map.put(:host, "other.stewardacs.xyz")
      |> post("/users/log_in", %{
        "user" => %{"username" => "acme-admin", "password" => "acme-secret"}
      })

    assert redirected_to(conn) == "/users/log_in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "does not match"
    refute Acs.Accounts.get_user_by_email("admin@localhost", "acme")
  end

  defp restore_env(key, nil), do: Application.delete_env(:steward_acs, key)
  defp restore_env(key, value), do: Application.put_env(:steward_acs, key, value)
end
