defmodule Acs.MCP.OAuth.Management do
  @moduledoc """
  Auth0 Management API v2 client for programmatic user management.

  Uses a Machine-to-Machine Application client credentials grant to obtain
  a Management API token, then calls `POST /api/v2/users` to provision users.

  Only available when OAuth Bearer auth is enabled (remote ACS deployments).
  """

  alias Acs.MCP.OAuth.Config

  require Logger

  @doc """
  Create a user in the Auth0 tenant via the Management API v2.

  Returns `{:ok, user_map}` on success or `{:error, reason}`.
  """
  def create_user(name, email, opts \\ []) do
    role = Keyword.get(opts, :role, "collaborator")
    org = Keyword.get(opts, :org, "default")
    connection = default_connection()
    password = Keyword.get(opts, :password)

    with {:ok, token} <- get_management_token(),
         {:ok, user} <- do_create_user(token, name, email, role, org, connection, password) do
      {:ok, user}
    end
  end

  defp management_api_url do
    domain = Config.domain()
    "https://#{domain}/api/v2/"
  end

  defp token_url do
    domain = Config.domain()
    "https://#{domain}/oauth/token"
  end

  defp client_id do
    Application.get_env(:steward_acs, :auth0_mgmt_client_id)
  end

  defp client_secret do
    Application.get_env(:steward_acs, :auth0_mgmt_client_secret)
  end

  defp configured? do
    is_binary(client_id()) and client_id() != "" and
      is_binary(client_secret()) and client_secret() != ""
  end

  defp get_management_token do
    unless configured?() do
      raise "AUTH0_MGMT_CLIENT_ID and AUTH0_MGMT_CLIENT_SECRET must be configured"
    end

    url = token_url()
    audience = "https://#{Config.domain()}/api/v2/"

    body = %{
      client_id: client_id(),
      client_secret: client_secret(),
      audience: audience,
      grant_type: "client_credentials"
    }

    case Req.post(url, json: body, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} ->
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        {:error, "Auth0 token request failed: HTTP #{status} #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Auth0 token request failed: #{inspect(reason)}"}
    end
  end

  defp default_connection do
    Application.get_env(:steward_acs, :auth0_connection, "email")
  end

  defp do_create_user(token, name, email, role, org, connection, password) do
    url = management_api_url() <> "users"

    headers = [
      {"authorization", "Bearer #{token}"},
      {"content-type", "application/json"}
    ]

    password_required = not passwordless_connection?(connection)
    effective_password = if password_required, do: password || generate_password()

    body =
      %{
        email: email,
        name: name,
        connection: connection,
        email_verified: true,
        app_metadata: %{
          role: role,
          org: org
        }
      }
      |> then(fn b -> if effective_password, do: Map.put(b, :password, effective_password), else: b end)

    case Req.post(url, json: body, headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: 201, body: user}} when is_map(user) ->
        {:ok, format_user(user)}

      {:ok, %{status: 409, body: %{"message" => msg}}} ->
        {:error, "User already exists: #{msg}"}

      {:ok, %{status: status, body: body}} ->
        {:error, "Auth0 create user failed: HTTP #{status} #{inspect(body)}"}

      {:error, reason} ->
        {:error, "Auth0 create user failed: #{inspect(reason)}"}
    end
  end

  defp passwordless_connection?(connection) do
    connection in ["email", "sms"]
  end

  defp generate_password do
    :crypto.strong_rand_bytes(24) |> Base.encode64(padding: false)
  end

  defp format_user(user) do
    %{
      id: user["user_id"],
      email: user["email"],
      name: user["name"],
      role: get_in(user, ["app_metadata", "role"]) || "collaborator",
      org: get_in(user, ["app_metadata", "org"]) || "default",
      email_verified: user["email_verified"],
      created_at: user["created_at"],
      provider: "auth0"
    }
  end
end
