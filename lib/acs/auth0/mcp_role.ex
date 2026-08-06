defmodule Acs.Auth0.McpRole do
  @moduledoc """
  Assigns Auth0 MCP connector roles to every Auth0 identity for an email.

  Email OTP and Google are separate Auth0 users. Connectors need `mcp:tools`
  (via **MCP User** / **claude_mcp**) on whichever identity signs in.

  Called from org create, member invite, invite accept, and OIDC upsert when
  the ACS user belongs to an org. Best-effort: failures are logged only.
  """

  require Logger

  alias Acs.Auth0.Management

  @role_names ["MCP User", "claude_mcp"]

  @doc "Fire-and-forget role assign for all Auth0 users with this email."
  @spec ensure_for_email_async(String.t() | nil) :: :ok
  def ensure_for_email_async(email) when is_binary(email) and email != "" do
    if Management.configured?() do
      # ponytail: one-shot Task; ceiling is Auth0 rate limits on burst invites.
      Task.start(fn ->
        case ensure_for_email(email) do
          :ok ->
            Logger.info("[Auth0.McpRole] ensured MCP roles for email=#{email}")

          {:error, :no_auth0_users} ->
            Logger.info(
              "[Auth0.McpRole] no Auth0 users yet for email=#{email} (will retry on next login)"
            )

          {:error, reason} ->
            Logger.warning("[Auth0.McpRole] ensure failed email=#{email}: #{inspect(reason)}")
        end
      end)
    end

    :ok
  end

  def ensure_for_email_async(_), do: :ok

  @doc "Synchronously assign MCP User + claude_mcp to all Auth0 users for email."
  @spec ensure_for_email(String.t()) :: :ok | {:error, term()}
  def ensure_for_email(email) when is_binary(email) and email != "" do
    email = String.trim(email) |> String.downcase()

    with {:ok, cfg} <- Management.config(),
         {:ok, token} <- Management.token(cfg),
         {:ok, role_ids} <- role_ids(cfg, token),
         {:ok, users} <- users_by_email(cfg, token, email) do
      if users == [] do
        {:error, :no_auth0_users}
      else
        Enum.reduce_while(users, :ok, fn user, :ok ->
          case assign_roles(cfg, token, user, role_ids) do
            :ok -> {:cont, :ok}
            {:error, _} = err -> {:halt, err}
          end
        end)
      end
    end
  end

  def ensure_for_email(_), do: {:error, :invalid_email}

  defp role_ids(cfg, token) do
    case Management.get(cfg, token, "/api/v2/roles") do
      {:ok, roles} when is_list(roles) ->
        ids =
          roles
          |> Enum.filter(&(&1["name"] in @role_names))
          |> Enum.map(& &1["id"])
          |> Enum.reject(&is_nil/1)

        if ids == [] do
          {:error, :roles_not_found}
        else
          {:ok, ids}
        end

      other ->
        other
    end
  end

  defp users_by_email(cfg, token, email) do
    q = URI.encode_www_form(email)

    case Management.get(cfg, token, "/api/v2/users-by-email?email=#{q}") do
      {:ok, users} when is_list(users) -> {:ok, users}
      other -> other
    end
  end

  defp assign_roles(cfg, token, %{"user_id" => user_id}, role_ids)
       when is_binary(user_id) do
    case Management.get(cfg, token, "/api/v2/users/#{URI.encode(user_id)}/roles") do
      {:ok, existing} when is_list(existing) ->
        have = MapSet.new(Enum.map(existing, & &1["id"]))
        missing = Enum.reject(role_ids, &MapSet.member?(have, &1))

        if missing == [] do
          :ok
        else
          case Management.post(cfg, token, "/api/v2/users/#{URI.encode(user_id)}/roles", %{
                 roles: missing
               }) do
            {:ok, _} -> :ok
            other -> other
          end
        end

      other ->
        other
    end
  end

  defp assign_roles(_cfg, _token, _user, _role_ids), do: {:error, :invalid_user}
end
