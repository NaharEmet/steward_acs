defmodule AcsWeb.UserSessionController do
  use AcsWeb, :controller

  alias Acs.Accounts
  alias AcsWeb.UserAuth

  defp auth_config do
    Application.get_env(:steward_acs, :basic_auth, %{username: "admin", password: "admin"})
  end

  def new(conn, _params) do
    render(conn, :new, layout: false)
  end

  def create(conn, %{"user" => %{"username" => username, "password" => password}}) do
    config = auth_config()

    if username == config[:username] and password == config[:password] do
      case Accounts.get_or_register_user("admin@localhost") do
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
end
