defmodule AcsWeb.UserAuthTest do
  use Acs.DataCase, async: false

  alias Acs.Accounts
  alias AcsWeb.UserAuth

  test "login stores the authenticated user's org in the dashboard session" do
    {:ok, user} = Accounts.register_user(%{email: "dashboard@example.test", org: "acme"})

    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Test.init_test_session(%{})
      |> UserAuth.log_in_user(user)

    assert Plug.Conn.get_session(conn, :current_org) == "acme"
    assert Plug.Conn.get_session(conn, :user_token)
  end

  test "session user restores active org on a neutral host" do
    {:ok, user} = Accounts.register_user(%{email: "neutral@example.test", org: "acme"})
    token = Accounts.generate_user_session_token(user)

    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Test.init_test_session(%{user_token: token})
      |> UserAuth.fetch_current_user([])

    assert conn.assigns.current_user.id == user.id
    assert conn.assigns.current_org == "acme"
    assert Plug.Conn.get_session(conn, :current_org) == "acme"
    assert Acs.Org.current() == "acme"
  end

  test "LiveView mount rejects a socket host hint that mismatches user org" do
    {:ok, user} = Accounts.register_user(%{email: "live-mismatch@example.test", org: "acme"})
    token = Accounts.generate_user_session_token(user)

    socket = %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}},
      private: %{connect_info: %{uri: URI.parse("wss://other.stewardacs.xyz/live")}}
    }

    assert {:halt, redirected_socket} =
             UserAuth.on_mount(
               :ensure_authenticated,
               %{},
               %{"user_token" => token, "current_org" => "acme"},
               socket
             )

    assert redirected_socket.redirected
  end

  test "session is rejected when host hint mismatches user org" do
    {:ok, user} = Accounts.register_user(%{email: "mismatch@example.test", org: "acme"})
    token = Accounts.generate_user_session_token(user)

    conn =
      Plug.Test.conn(:get, "/")
      |> Plug.Test.init_test_session(%{user_token: token})
      |> Plug.Conn.assign(:org_hint, "other")
      |> UserAuth.fetch_current_user([])

    assert conn.assigns.current_user == nil
    refute Map.has_key?(conn.assigns, :current_org)
  end
end
