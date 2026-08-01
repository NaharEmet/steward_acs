defmodule Acs.MCP.Tools.PersonHandlers do
  @moduledoc """
  MCP handlers for the person status directory (data authority + job status).
  """
  alias Acs.AuthorityLevels
  alias Acs.PersonStatus

  def get_person_status(args) do
    org = Acs.Org.current()
    email = blank_to_nil(args["email"])
    name = blank_to_nil(args["name"])

    cond do
      is_nil(email) and is_nil(name) ->
        {:error, "email or name is required"}

      true ->
        case PersonStatus.get(org, email: email, name: name) do
          nil ->
            levels = AuthorityLevels.list(org)

            {:ok,
             %{
               found: false,
               hint:
                 "No status on file. Ask the user for this person's job status/title and authority level, then call set_person_status. Allowed levels: " <>
                   Enum.map_join(levels, ", ", &"#{&1.label} (#{&1.slug})")
             }}

          person ->
            {:ok, Map.put(PersonStatus.to_map(person), :found, true)}
        end
    end
  end

  def set_person_status(args) do
    org = Acs.Org.current()
    email = blank_to_nil(args["email"])
    name = blank_to_nil(args["name"])
    status = blank_to_nil(args["status"])
    rank_input = blank_to_nil(args["rank"]) || "standard"
    updated_by = args["_auth_attribution"] || args["_auth_agent_id"]

    cond do
      is_nil(email) and is_nil(name) ->
        {:error, "email or name is required"}

      is_nil(status) ->
        {:error, "status is required"}

      is_nil(AuthorityLevels.resolve(org, rank_input)) ->
        levels = AuthorityLevels.list(org)

        {:error,
         "rank must be an org authority level: " <>
           Enum.map_join(levels, ", ", &"#{&1.label} (#{&1.slug})")}

      true ->
        attrs = %{
          "org" => org,
          "email" => email,
          "name" => name,
          "status" => status,
          "rank" => rank_input,
          "updated_by" => updated_by
        }

        case PersonStatus.upsert(attrs) do
          {:ok, person} ->
            {:ok,
             %{
               status: "ok",
               person: PersonStatus.to_map(person)
             }}

          {:error, %Ecto.Changeset{} = cs} ->
            {:error, "Validation failed: #{inspect(cs.errors)}"}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    t = String.trim(s)
    if t == "", do: nil, else: t
  end

  defp blank_to_nil(_), do: nil
end
