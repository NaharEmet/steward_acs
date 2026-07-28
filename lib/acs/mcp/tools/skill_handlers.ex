defmodule Acs.MCP.Tools.SkillHandlers do
  @moduledoc """
  Handles skill discovery and governance MCP tools.
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

      scope_path = args["scope_path"] ->
        results = Store.list_skills_by_scope(scope_path)
        {:ok, %{skills: results, total: length(results)}}

      true ->
        results = Store.list_skills()
        {:ok, %{skills: results, total: length(results)}}
    end
  end

  def skill_save(args) do
    name = blank_to_nil(args["name"])
    content = blank_to_nil(args["content"])

    cond do
      is_nil(name) ->
        {:error, "name is required"}

      is_nil(content) ->
        {:error, "content is required"}

      true ->
        {:ok, intake} = Acs.Skills.Intake.review(args)

        if blocking_intake?(intake, args) do
          {:ok, intake_questions_payload(args, intake)}
        else
          do_save(args, name, content, intake)
        end
    end
  end

  defp do_save(args, name, content, intake) do
    description = blank_to_nil(args["description"]) || intake.suggested_description
    when_to_use = blank_to_nil(args["when_to_use"]) || intake.suggested_when_to_use
    tags = args["tags"] || []
    scope_paths = args["scope_paths"] || []

    case Store.save_skill(name, content,
           description: description,
           when_to_use: when_to_use,
           tags: tags,
           scope_paths: scope_paths,
           status: "proposed"
         ) do
      {:ok, saved} ->
        # Post-save LLM quality audit (evaluate.md) — feeds governance UI + meta loops
        Acs.Skills.Auditor.audit_soon(saved.name)

        {:ok,
         %{
           status: "saved",
           saved: true,
           name: saved.name,
           id: saved.id,
           skill_status: saved.status,
           intake: intake_summary(intake),
           note:
             if(intake.suggested_sensitive,
               do: "Saved as proposed, but content looked sensitive — prefer vault/env refs.",
               else: nil
             )
         }
         |> reject_nil_values()}

      {:error, reason} ->
        {:error, "Failed to save skill: #{inspect(reason)}"}
    end
  end

  # Single-pass gate: block only when intake has a question (or allow=false).
  # Soft suggestions never block. intake_confirmed bypasses.
  defp blocking_intake?(intake, args) do
    if truthy?(args["intake_confirmed"]) do
      false
    else
      intake.questions != [] or intake.allow == false
    end
  end

  defp intake_questions_payload(args, intake) do
    %{
      status: "needs_input",
      saved: false,
      question:
        intake.notes ||
          "Intake needs one clarification before saving. Ask the user if needed, fix, then retry skill_save (or intake_confirmed: true).",
      questions: intake.questions,
      suggested_description: intake.suggested_description,
      suggested_when_to_use: intake.suggested_when_to_use,
      suggested_sensitive: intake.suggested_sensitive,
      needs_improvement: intake.needs_improvement,
      intake: intake_summary(intake),
      retry_hint:
        "Single pass: apply the answer, then retry skill_save once (intake_confirmed: true if confirming as-is).",
      draft: %{
        name: args["name"],
        description: args["description"],
        when_to_use: args["when_to_use"]
      }
    }
  end

  defp intake_summary(intake) do
    %{
      source: intake.source,
      allow: intake.allow,
      suggested_sensitive: intake.suggested_sensitive,
      needs_improvement: intake.needs_improvement,
      notes: intake.notes
    }
  end

  defp reject_nil_values(map) do
    Map.reject(map, fn {_k, v} -> is_nil(v) end)
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?("yes"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    t = String.trim(s)
    if t == "", do: nil, else: t
  end

  defp blank_to_nil(_), do: nil
end
