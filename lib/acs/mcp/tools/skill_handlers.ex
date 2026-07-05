defmodule Acs.MCP.Tools.SkillHandlers do
  @moduledoc """
  Handles skill management MCP tools: `skill_get` and `skill_save`.
  """
  alias Acs.Skills.Store

  def skill_audit_status(_args) do
    results = Acs.Skills.Auditor.audit_all()

    skills =
      Enum.map(results, fn r ->
        Map.take(r, [:audit_status, :audit_score, :audit_reasoning, :audited_at])
        |> Map.put(:name, r.name)
      end)

    {:ok, %{skills: skills, total: length(results)}}
  end

  def skill_get(args) do
    cond do
      name = args["name"] ->
        case Store.get_skill(name) do
          nil -> {:ok, %{skills: [], total: 0, error: "skill '#{name}' not found"}}
          skill -> {:ok, %{skills: [skill], total: 1}}
        end

      search = args["search"] ->
        results = Store.search_skills(search)
        {:ok, %{skills: results, total: length(results)}}

      tag = args["tag"] ->
        results = Store.list_skills(tag)
        {:ok, %{skills: results, total: length(results)}}

      true ->
        results = Store.list_skills()
        {:ok, %{skills: results, total: length(results)}}
    end
  end

  def skill_save(args) do
    name = args["name"]
    content = args["content"]

    cond do
      is_nil(name) or name == "" ->
        {:error, "name is required"}

      is_nil(content) or content == "" ->
        {:error, "content is required"}

      true ->
        tags = args["tags"] || []
        description = args["description"]
        Store.save_skill(name, content, tags, description)
    end
  end
end
