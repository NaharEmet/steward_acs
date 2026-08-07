defmodule Acs.MCP.Tools.AuthorityHandlers do
  @moduledoc """
  Admin MCP handlers for org data-authority level catalog and member clearance.
  """

  alias Acs.Accounts
  alias Acs.Accounts.User
  alias Acs.AuthorityLevel
  alias Acs.AuthorityLevels
  alias Acs.Repo

  def list_authority_levels(args) do
    org = args["_auth_org_id"] || Acs.Org.current()
    levels = AuthorityLevels.list(org)

    {:ok,
     %{
       org: org,
       levels: Enum.map(levels, &AuthorityLevels.to_map/1),
       count: length(levels),
       max: AuthorityLevels.max_levels()
     }}
  end

  def upsert_authority_level(args) do
    org = args["_auth_org_id"] || Acs.Org.current()

    case AuthorityLevels.upsert(org, args) do
      {:ok, level} ->
        {:ok, %{status: "ok", level: AuthorityLevels.to_map(level)}}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, "Validation failed: #{inspect(cs.errors)}"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  def delete_authority_level(args) do
    org = args["_auth_org_id"] || Acs.Org.current()
    slug = args["slug"]
    remap = args["remap"] || args["remap_to"]

    if is_nil(slug) or slug == "" do
      {:error, "slug is required"}
    else
      opts = if remap in [nil, ""], do: [], else: [remap: remap]

      case AuthorityLevels.delete(org, slug, opts) do
        {:ok, %AuthorityLevel{} = level} ->
          {:ok, %{status: "deleted", slug: level.slug}}

        {:ok, %{deleted: level} = result} ->
          {:ok,
           %{
             status: "deleted",
             slug: level.slug,
             remapped_to: result.remapped_to,
             remapped: result.remapped
           }}

        {:error, :remap_required, info} ->
          {:ok, Map.put(info, :status, "needs_remap")}

        {:error, :not_found} ->
          {:error, "Authority level not found"}

        {:error, reason} when is_binary(reason) ->
          {:error, reason}

        {:error, reason} ->
          {:error, inspect(reason)}
      end
    end
  end

  def set_member_authority_level(args) do
    email = blank(args["email"])
    user_id = args["user_id"]
    level = blank(args["authority_level"] || args["rank"] || args["slug"])
    org = args["_auth_org_id"] || Acs.Org.current()

    cond do
      is_nil(level) ->
        {:error, "authority_level is required (label or slug)"}

      true ->
        with {:ok, actor} <- resolve_actor(args, org),
             {:ok, target} <- resolve_target(org, email, user_id),
             {:ok, user} <- Accounts.change_authority_level(actor, target.id, level) do
          {:ok,
           %{
             status: "ok",
             email: user.email,
             authority_level_slug: user.authority_level_slug
           }}
        else
          {:error, reason} when is_atom(reason) ->
            {:error, Atom.to_string(reason)}

          {:error, reason} when is_binary(reason) ->
            {:error, reason}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
    end
  end

  defp resolve_actor(args, org) do
    attribution = args["_auth_attribution"] || args["_auth_agent_id"]

    cond do
      is_binary(attribution) and String.contains?(attribution, "@") ->
        case Accounts.get_user_by_email(attribution, org) do
          %User{} = user -> {:ok, user}
          _ -> {:error, "Authenticated user not found for authority changes"}
        end

      is_binary(attribution) and attribution != "" ->
        org_struct = Acs.Orgs.get_by_slug(org)
        members = if org_struct, do: Accounts.list_members(org_struct), else: []

        case Enum.find(members, fn u ->
               User.display_name(u) == attribution and u.org_role in ~w(owner admin)
             end) do
          %User{} = user ->
            {:ok, user}

          nil ->
            {:error,
             "set_member_authority_level requires an authenticated org admin user (OAuth), not an API key"}
        end

      true ->
        {:error,
         "set_member_authority_level requires an authenticated org admin user (OAuth), not an API key"}
    end
  end

  defp resolve_target(org, email, user_id) do
    cond do
      is_integer(user_id) ->
        case Repo.get(User, user_id) do
          %User{} = u -> {:ok, u}
          nil -> {:error, "User not found"}
        end

      is_binary(user_id) and user_id != "" ->
        case Integer.parse(user_id) do
          {id, _} -> resolve_target(org, email, id)
          :error -> {:error, "user_id must be an integer"}
        end

      is_binary(email) ->
        case Accounts.get_user_by_email(email, org) do
          %User{} = u -> {:ok, u}
          _ -> {:error, "No member with email #{email}"}
        end

      true ->
        {:error, "email or user_id is required"}
    end
  end

  defp blank(nil), do: nil
  defp blank(""), do: nil
  defp blank(s) when is_binary(s), do: String.trim(s)
  defp blank(_), do: nil
end
