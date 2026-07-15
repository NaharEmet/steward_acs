defmodule Acs.ClaimContext do
  @moduledoc """
  Finds skills and specs relevant to a task at claim time.
  """

  alias Acs.Skills.Store
  alias Acs.Specs.{Entry, Loader, Search}

  @max_skills 5
  @max_specs 5
  @default_app "steward_acs"

  @doc """
  Returns `%{relevant_skills: [...], relevant_specs: [...]}` for a task map or struct.
  """
  def for_task(task) do
    task_map = if is_struct(task), do: Map.from_struct(task), else: task
    query = build_query(task_map)
    file_paths = task_map[:file_paths] || task_map["file_paths"] || []
    scope_path = scope_from_file_paths(file_paths)

    task_skills = relevant_skills(query)
    scope_skills = skills_for_scope(scope_path)

    %{
      relevant_skills: merge_skills(task_skills, scope_skills),
      relevant_specs: relevant_specs(query, file_paths)
    }
  end

  @doc """
  Returns skills and specs relevant to a scope path (e.g. from generate_guidance_packet).
  """
  def for_scope(scope_path) when is_binary(scope_path) do
    %{
      relevant_skills: skills_for_scope(scope_path),
      relevant_specs: specs_for_scope(scope_path)
    }
  end

  def for_scope(_), do: %{relevant_skills: [], relevant_specs: []}

  @doc "Skills tagged or scoped to this path."
  def skills_for_scope(scope_path) do
    Store.search_skills(scope_path)
    |> Enum.take(@max_skills)
    |> Enum.map(&skill_summary/1)
  end

  defp specs_for_scope(scope_path) when is_binary(scope_path) do
    scope = String.trim(scope_path)
    if scope == "", do: [], else: do_specs_for_scope(scope)
  end

  defp specs_for_scope(_), do: []

  defp do_specs_for_scope(scope) do
    case Search.search(scope, limit: @max_specs) do
      {:ok, entries} -> Enum.map(entries, &spec_summary/1)
      _ -> []
    end
  end

  defp merge_skills(a, b) do
    (a ++ b)
    |> Enum.uniq_by(fn s -> s.name || s[:name] end)
    |> Enum.take(@max_skills)
  end

  defp scope_from_file_paths([path | _]) when is_binary(path) do
    if String.contains?(path, "/lib/") do
      {_module, spec_path} = Loader.file_to_module_path(path)
      spec_path
    else
      path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")
    end
  end

  defp scope_from_file_paths(_), do: ""

  defp build_query(task_map) do
    [task_map[:title] || task_map["title"], task_map[:description] || task_map["description"]]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join(" ")
    |> String.trim()
  end

  defp relevant_skills("") do
    Store.list_skills() |> Enum.take(@max_skills)
  end

  defp relevant_skills(query) do
    Store.search_skills(query)
    |> Enum.take(@max_skills)
    |> Enum.map(&skill_summary/1)
  end

  defp skill_summary(skill) when is_map(skill) do
    %{
      name: Map.get(skill, :name) || Map.get(skill, "name"),
      description: Map.get(skill, :description) || Map.get(skill, "description"),
      tags: Map.get(skill, :tags) || Map.get(skill, "tags") || [],
      when_to_use: Map.get(skill, :description) || Map.get(skill, "description") || ""
    }
  end

  defp relevant_specs(query, file_paths) do
    from_paths = specs_from_file_paths(file_paths)

    from_search =
      if query == "" do
        []
      else
        case Search.search(query, limit: @max_skills) do
          {:ok, entries} -> entries
          _ -> []
        end
      end

    (from_paths ++ from_search)
    |> Enum.uniq_by(fn entry -> {entry.app, entry.id} end)
    |> Enum.take(@max_specs)
    |> Enum.map(&spec_summary/1)
  end

  defp specs_from_file_paths(file_paths) when is_list(file_paths) do
    file_paths
    |> Enum.flat_map(&spec_from_file_path/1)
    |> Enum.reject(&is_nil/1)
  end

  defp specs_from_file_paths(_), do: []

  defp spec_from_file_path(path) when is_binary(path) do
    if String.contains?(path, "/lib/") do
      {_module, spec_path} = Loader.file_to_module_path(path)
      app = detect_app_from_path(path)

      case Loader.load(app, spec_path) do
        {:ok, entry} -> [entry]
        _ -> [%Entry{app: app, id: spec_path, title: spec_path, status: "missing"}]
      end
    else
      []
    end
  end

  defp spec_from_file_path(_), do: []

  defp detect_app_from_path(path) do
    parts = Path.split(path)
    lib_idx = Enum.find_index(parts, &(&1 == "lib"))

    if lib_idx && lib_idx > 0 do
      Enum.at(parts, lib_idx - 1) || @default_app
    else
      @default_app
    end
  end

  defp spec_summary(%Entry{} = entry) do
    %{
      app: entry.app,
      path: entry.id,
      title: entry.title,
      purpose: entry.purpose,
      status: entry.status
    }
  end

end
