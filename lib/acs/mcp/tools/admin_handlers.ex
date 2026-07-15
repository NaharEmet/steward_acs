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
    org = Map.get(args, "_auth_org_id", Acs.Org.current())

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

  def list_keys(args) do
    org = Map.get(args, "_auth_org_id", Acs.Org.current())
    developers = Developers.list_developers(org)

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
      case Developers.revoke(id, Map.get(args, "_auth_org_id", Acs.Org.current())) do
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

  def create_org(args) do
    name = Map.get(args, "name")
    slug = Map.get(args, "slug")
    subdomain = Map.get(args, "subdomain", slug)
    plan = Map.get(args, "plan", "free")

    cond do
      is_nil(name) or name == "" ->
        {:error, "name is required"}

      is_nil(slug) or slug == "" ->
        {:error, "slug is required"}

      true ->
        case Acs.Orgs.create(%{name: name, slug: slug, subdomain: subdomain, plan: plan}) do
          {:ok, org} ->
            vault_base = Application.get_env(:steward_acs, :obsidian_vault_path)

            if Acs.Org.multi_tenant?() and is_binary(vault_base) do
              File.mkdir_p!(Acs.Org.memory_dir(org.slug))
              File.mkdir_p!(Acs.Specs.Loader.specs_path(org.slug))
              File.mkdir_p!(Acs.Skills.Store.skill_dir(org.slug))
            end

            {:ok,
             %{
               id: org.id,
               name: org.name,
               slug: org.slug,
               subdomain: org.subdomain,
               plan: org.plan,
               url: "https://#{org.subdomain}.#{Acs.Org.base_domain()}",
               obsidian_url: "https://#{org.subdomain}.obsidian.#{Acs.Org.base_domain()}",
               syncthing_note:
                 "Add syncthing_#{org.subdomain} service to docker-compose and a Caddy route for #{org.subdomain}.obsidian.#{Acs.Org.base_domain()}"
             }}

          {:error, errors} ->
            {:error, "Failed to create org: #{inspect(errors)}"}
        end
    end
  end

  def create_user(args) do
    name = Map.get(args, "name")
    email = Map.get(args, "email")
    role = Map.get(args, "role", "collaborator")
    password = Map.get(args, "password")
    org = Map.get(args, "_auth_org_id", Acs.Org.current())

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
