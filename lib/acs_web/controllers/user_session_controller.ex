defmodule AcsWeb.UserSessionController do
  use AcsWeb, :controller

  alias Acs.Accounts
  alias AcsWeb.UserAuth

  require Logger

  defp auth_config(org \\ nil) do
    per_org = Application.get_env(:steward_acs, :basic_auth_by_org, %{})

    case org && Map.get(per_org, org) do
      %{username: _, password: _} = config -> config
      _ -> Application.get_env(:steward_acs, :basic_auth, %{username: "admin", password: "admin"})
    end
  end

  def new(conn, _params) do
    config = auth_config()

    if config[:username] == "admin" and config[:password] == "admin" do
      Logger.warning(
        "[Auth] Dashboard using default admin/admin credentials — set ACS_USERNAME/ACS_PASSWORD env vars"
      )
    end

    render(conn, :new, layout: false)
  end

  def create(conn, %{"user" => %{"username" => username, "password" => password}}) do
    org = conn.assigns[:current_org] || Acs.Org.current()
    config = auth_config(org)

    if dashboard_org_allowed?(org) and secure_compare(username, config[:username]) and
         secure_compare(password, config[:password]) do
      case Accounts.get_or_register_user("admin@localhost", org) do
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

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end

  defp dashboard_org_allowed?(org) do
    per_org = Application.get_env(:steward_acs, :basic_auth_by_org, %{})
    org == Acs.Org.configured() or Map.has_key?(per_org, org)
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_compare(_, _), do: false
end
