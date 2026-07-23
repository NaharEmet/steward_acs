defmodule Acs.MCP.Tools.AdminHandlers do
  @moduledoc """
  Handlers for admin-only MCP tools.
  """
  alias Acs.Developers
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

  def create_user(_args) do
    {:error, "MCP user creation is deprecated. Invite users from the dashboard instead."}
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_iso8601(ndt)
end
