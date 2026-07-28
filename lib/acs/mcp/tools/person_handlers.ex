defmodule Acs.MCP.Tools.PersonHandlers do
  @moduledoc """
  MCP handlers for the person status directory (authority + sensitivity rank).
  """

  alias Acs.PersonStatus

  def get_person_status(args) do
    org = Acs.Org.current()
    email = blank_to_nil(args["email"])
    name = blank_to_nil(args["name"])

    cond do
      is_nil(email) and is_nil(name) ->
        {:error, "Provide email and/or name to look up a person"}

      true ->
        case PersonStatus.get(org, email: email, name: name) do
          nil ->
            {:ok,
             %{
               found: false,
               message:
                 "No status on file. Ask the user for this person's job status/title and rank (high|elevated|standard), then call set_person_status."
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
    rank = blank_to_nil(args["rank"]) || "standard"

    cond do
      is_nil(status) ->
        {:error, "status is required (job title / role, e.g. CEO, VP Sales, Engineer)"}

      is_nil(email) and is_nil(name) ->
        {:error, "Provide email and/or name"}

      rank not in PersonStatus.ranks() ->
        {:error, "rank must be one of: #{Enum.join(PersonStatus.ranks(), ", ")}"}

      true ->
        attrs = %{
          "org" => org,
          "email" => email,
          "name" => name || email,
          "status" => status,
          "rank" => rank,
          "updated_by" => args["_auth_agent_id"] || Acs.Org.developer_name()
        }

        case PersonStatus.upsert(attrs) do
          {:ok, person} ->
            {:ok,
             %{
               message: "Person status saved",
               person: PersonStatus.to_map(person)
             }}

          {:error, changeset} ->
            {:error, "Failed to save person status: #{inspect(changeset.errors)}"}
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
