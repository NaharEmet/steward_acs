defmodule AcsWeb.UserAuth do
  @moduledoc """
  Session authentication for the dashboard.
  """
  use AcsWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.Component, only: [assign_new: 3]

  alias Acs.Accounts

  @session_key :user_token

  def log_in_user(conn, user, _params \\ %{}) do
    token = Accounts.generate_user_session_token(user)

    conn
    |> renew_session()
    |> put_session(@session_key, token)
    |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
    |> redirect(to: ~p"/")
  end

  def log_out_user(conn) do
    user_token = get_session(conn, @session_key)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      AcsWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session()
    |> redirect(to: ~p"/users/log_in")
  end

  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end

  def fetch_current_user(conn, _opts) do
    user_token = get_session(conn, @session_key)
    user = user_token && Accounts.get_user_by_session_token(user_token)
    assign(conn, :current_user, user)
  end

  def require_authenticated_user(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/users/log_in")
      |> halt()
    end
  end

  defp maybe_store_return_to(%{method: "GET"} = conn) do
    put_session(conn, :user_return_to, current_path(conn))
  end

  defp maybe_store_return_to(conn), do: conn

  def on_mount(:ensure_authenticated, _params, session, socket) do
    IO.puts("")
    IO.puts("=== on_mount(:ensure_authenticated) ===")
    IO.puts("Session keys: #{inspect(Map.keys(session))}")
    IO.puts("Session has user_token: #{inspect(Map.has_key?(session, "user_token"))}")
    IO.puts("Session user_token: #{inspect(session["user_token"])}")
    IO.puts("Socket endpoint: #{inspect(socket.endpoint)}")
    IO.puts("URI: #{inspect(socket.host_uri)}")

    socket =
      assign_new(socket, :current_user, fn ->
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end
      end)

    IO.puts("current_user: #{inspect(socket.assigns.current_user)}")
    IO.puts("=== end on_mount ===\n")

    if socket.assigns.current_user do
      {:cont, socket}
    else
      {:halt,
       Phoenix.LiveView.redirect(socket, to: ~p"/users/log_in")}
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
      {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/")}
    else
      {:cont, socket}
    end
  end
end
