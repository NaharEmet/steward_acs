defmodule Acs.MCP.Tools.AdminHandlers do
  @moduledoc """
  Handlers for admin-only MCP tools.
  """
  alias Acs.Developers
  alias Acs.MCP.OAuth.Management
  require Logger

  def generate_key(args) do
    name = Map.get(args, "name") || Map.get(args, "developer_name")
    role = Map.get(args, "role", "collaborator")
    org = Map.get(args, "_auth_org_id", "default")

    cond do
      is_nil(name) or name == "" ->
        {:error, "name is required"}

      role not in ~w(admin service reader collaborator) ->
        {:error, "role must be one of: admin, service, reader, collaborator"}

      true ->
        case Developers.generate_key(name, role: role, org: org) do
          {:ok, %{key: raw_key, developer: dev}} ->
            {:ok,
             %{
               key: raw_key,
               key_prefix: dev.key_prefix,
               developer_name: dev.developer_name,
               role: dev.role,
               org: dev.org,
               id: dev.id
             }}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  def list_keys(_args) do
    developers = Developers.list_developers()

    entries =
      Enum.map(developers, fn dev ->
        %{
          id: dev.id,
          developer_name: dev.developer_name,
          role: dev.role,
          org: dev.org,
          key_prefix: dev.key_prefix,
          active: dev.active,
          last_used_at: format_datetime(dev.last_used_at),
          created_at: format_datetime(dev.inserted_at)
        }
      end)

    {:ok, %{developers: entries, total: length(entries)}}
  end

  def revoke_key(args) do
    id = Map.get(args, "id")

    if is_nil(id) or id == "" do
      {:error, "id is required"}
    else
      case Developers.revoke(id) do
        {:ok, dev} ->
          {:ok,
           %{
             id: dev.id,
             developer_name: dev.developer_name,
             active: dev.active,
             status: "revoked"
           }}

        {:error, :not_found} ->
          {:error, "Developer key not found"}

        {:error, reason} ->
          {:error, "Failed to revoke key: #{inspect(reason)}"}
      end
    end
  end

  def create_user(args) do
    name = Map.get(args, "name")
    email = Map.get(args, "email")
    role = Map.get(args, "role", "collaborator")
    password = Map.get(args, "password")
    org = Map.get(args, "_auth_org_id", "default")

    cond do
      is_nil(name) or name == "" ->
        {:error, "name is required"}

      is_nil(email) or email == "" ->
        {:error, "email is required"}

      not Acs.MCP.OAuth.Config.enabled?() ->
        {:error,
         "OAuth is not enabled. This tool is only available in remote ACS deployments with Auth0 configured."}

      not is_binary(Application.get_env(:steward_acs, :auth0_mgmt_client_id)) ->
        {:error,
         "Auth0 Management API credentials not configured. Set AUTH0_MGMT_CLIENT_ID and AUTH0_MGMT_CLIENT_SECRET."}

      true ->
        opts = [role: role, org: org] |> then(fn o -> if password, do: Keyword.put(o, :password, password), else: o end)

        case Management.create_user(name, email, opts) do
          {:ok, user} ->
            {:ok, user}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
end
