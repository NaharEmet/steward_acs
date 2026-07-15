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
    with {:ok, credential_org} <- authenticate_dashboard_credentials(username, password),
         {:ok, org} <- Acs.Org.resolve_active_org(credential_org),
         :ok <- Acs.Org.validate_hint(org, conn.assigns[:org_hint]),
         {:ok, user} <- Accounts.get_or_register_user("admin@localhost", org) do
      UserAuth.log_in_user(conn, user)
    else
      {:error, :org_hint_mismatch} ->
        conn
        |> put_flash(:error, "Authenticated organization does not match request host.")
        |> redirect(to: ~p"/users/log_in")

      {:error, reason} when reason in [:invalid_credentials, :ambiguous_credentials] ->
        conn
        |> put_flash(:error, "Invalid username or password.")
        |> redirect(to: ~p"/users/log_in")

      {:error, _} ->
        conn
        |> put_flash(:error, "Could not create user.")
        |> redirect(to: ~p"/users/log_in")
    end
  end

  def delete(conn, _params) do
    UserAuth.log_out_user(conn)
  end

  defp authenticate_dashboard_credentials(username, password) do
    configured = Acs.Org.configured()
    per_org = Application.get_env(:steward_acs, :basic_auth_by_org, %{})

    matches =
      [{configured, auth_config(configured)} | Map.to_list(per_org)]
      |> Enum.filter(fn {_org, config} ->
        secure_compare(username, config[:username]) and
          secure_compare(password, config[:password])
      end)
      |> Enum.uniq_by(&elem(&1, 0))

    case matches do
      [{org, _config}] -> {:ok, org}
      [] -> {:error, :invalid_credentials}
      _ -> {:error, :ambiguous_credentials}
    end
  end

  defp secure_compare(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_compare(_, _), do: false
end
