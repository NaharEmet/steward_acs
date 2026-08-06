defmodule Acs.ClaimContext do
  @moduledoc """
  Finds skills and specs relevant to a task at claim time.

  Never backfills the catalog when nothing matches — empty is better than
  dumping the first N unrelated skills into guidance / `_next`.
  """

  alias Acs.Skills.Store
  alias Acs.Specs.{Entry, Loader, Search}

  @max_skills 3
  @max_specs 3
  @default_app "steward_acs"

  # Tokens too common to imply relevance on their own.
  @stopwords MapSet.new(~w(
    a an the to for of and or with from this that is are be by on in at as it its
    vs via when how what why fix bug issue task work add update make get set use
    new old into over under after before about onto
    url urls http https path name file code test tests smoke module app
  ))

  # Require at least a name (+10) or tag (+8) hit — description-only is too weak.
  @min_skill_score 8

  @doc """
  Returns `%{relevant_skills: [...], relevant_specs: [...]}` for a task map or struct.
  """
  def for_task(task) do
    task_map = if is_struct(task), do: Map.from_struct(task), else: task
    query = build_query(task_map)
    file_paths = task_map[:file_paths] || task_map["file_paths"] || []
    scope_path = scope_from_file_paths(file_paths)

    %{
      relevant_skills: merge_skills(relevant_skills(query), skills_for_scope(scope_path)),
      relevant_specs: relevant_specs(query, file_paths)
    }
  end

  @doc """
  Returns skills and specs relevant to a scope path (e.g. from generate_guidance_packet).
  """
  def for_scope(scope_path) when is_binary(scope_path) do
    scope = String.trim(scope_path)

    if scope == "" do
      %{relevant_skills: [], relevant_specs: []}
    else
      %{
        relevant_skills: skills_for_scope(scope),
        relevant_specs: specs_for_scope(scope)
      }
    end
  end

  def for_scope(_), do: %{relevant_skills: [], relevant_specs: []}

  @doc "Skills scoped to this path (prefix match on skill scope_paths)."
  def skills_for_scope(scope_path) when is_binary(scope_path) do
    scope = String.trim(scope_path)

    if scope == "" do
      []
    else
      Store.list_skills_by_scope(scope)
      |> Enum.take(@max_skills)
      |> Enum.map(&skill_summary/1)
    end
  end

  def skills_for_scope(_), do: []

  defp specs_for_scope(scope_path) when is_binary(scope_path) do
    scope = String.trim(scope_path)
    if scope == "", do: [], else: do_specs_for_scope(scope)
  end

  defp specs_for_scope(_), do: []

  defp do_specs_for_scope(scope) do
    case Search.search(scope, limit: @max_specs, mode: "keyword") do
      {:ok, entries} -> Enum.map(entries, &spec_summary/1)
      _ -> []
    end
  end

  defp merge_skills(a, b) do
    (a ++ b)
    |> Enum.uniq_by(fn s -> s.name || s[:name] end)
    |> Enum.take(@max_skills)
  end

  @doc """
  Derive a scope path from a task's file_paths, matching the claim-time scope
  format (spec path for /lib/ files, else the file's dirname). Used at claim
  time and by skill_save to pre-fill `scope_paths` from the caller's task.
  """
  def scope_from_file_paths([path | _]) when is_binary(path) do
    if String.contains?(path, "/lib/") do
      {_module, spec_path} = Loader.file_to_module_path(path)
      spec_path
    else
      path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")
    end
  end

  def scope_from_file_paths(_), do: ""

  defp build_query(task_map) do
    [task_map[:title] || task_map["title"], task_map[:description] || task_map["description"]]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.join(" ")
    |> String.trim()
  end

  defp relevant_skills(""), do: []

  defp relevant_skills(query) do
    tokens = meaningful_tokens(query)

    if tokens == [] do
      []
    else
      Store.all_skills()
      |> Enum.map(fn skill -> {skill, skill_token_score(skill, tokens)} end)
      |> Enum.filter(fn {_skill, score} -> score >= @min_skill_score end)
      |> Enum.sort_by(fn {_skill, score} -> score end, :desc)
      |> Enum.take(@max_skills)
      |> Enum.map(fn {skill, _score} -> skill_summary(skill) end)
    end
  end

  defp skill_token_score(skill, tokens) do
    name = String.downcase(Map.get(skill, :name) || Map.get(skill, "name") || "")
    desc = String.downcase(Map.get(skill, :description) || Map.get(skill, "description") || "")

    tags =
      (Map.get(skill, :tags) || Map.get(skill, "tags") || [])
      |> Enum.map(&String.downcase/1)

    scopes =
      (Map.get(skill, :scope_paths) || Map.get(skill, "scope_paths") || [])
      |> Enum.map(&String.downcase/1)

    Enum.reduce(tokens, 0, fn token, acc ->
      cond do
        String.contains?(name, token) -> acc + 10
        token in tags -> acc + 8
        Enum.any?(scopes, &String.contains?(&1, token)) -> acc + 5
        String.contains?(desc, token) -> acc + 3
        true -> acc
      end
    end)
  end

  defp skill_summary(skill) when is_map(skill) do
    %{
      name: Map.get(skill, :name) || Map.get(skill, "name"),
      description: Map.get(skill, :description) || Map.get(skill, "description"),
      when_to_use:
        Map.get(skill, :when_to_use) || Map.get(skill, "when_to_use") ||
          Map.get(skill, :description) || Map.get(skill, "description") || ""
    }
  end

  defp relevant_specs(query, file_paths) do
    from_paths = specs_from_file_paths(file_paths)
    tokens = meaningful_tokens(query)

    from_search =
      if tokens == [] do
        []
      else
        case Search.search(Enum.join(tokens, " "), limit: @max_specs * 3, mode: "keyword") do
          {:ok, entries} ->
            entries
            |> Enum.filter(&spec_token_hit?(&1, tokens))
            |> Enum.take(@max_specs)

          _ ->
            []
        end
      end

    (from_paths ++ from_search)
    |> Enum.uniq_by(fn entry ->
      {Map.get(entry, :app), Map.get(entry, :id) || Map.get(entry, :path)}
    end)
    |> Enum.take(@max_specs)
    |> Enum.map(&spec_summary/1)
  end

  # Prefer title/purpose/path hits over incidental body matches.
  defp spec_token_hit?(%Entry{} = entry, tokens) do
    haystack =
      [
        entry.id,
        entry.title,
        entry.purpose,
        entry.document_type,
        Enum.join(entry.tags || [], " ")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    Enum.any?(tokens, &String.contains?(haystack, &1))
  end

  defp spec_token_hit?(%{__rag_chunk: true} = chunk, tokens) do
    haystack =
      [Map.get(chunk, :path), Map.get(chunk, :context), Map.get(chunk, :title)]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
      |> String.downcase()

    Enum.any?(tokens, &String.contains?(haystack, &1))
  end

  defp spec_token_hit?(_, _), do: false

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

  defp spec_summary(%Entry{status: "missing"} = entry) do
    %{
      app: entry.app,
      path: entry.id,
      title: entry.title || entry.id,
      status: "missing"
    }
  end

  defp spec_summary(%Entry{} = entry) do
    %{
      app: entry.app,
      path: entry.id,
      title: entry.title,
      purpose: entry.purpose
    }
  end

  defp spec_summary(%{__rag_chunk: true} = chunk) do
    %{
      app: Map.get(chunk, :app),
      path: Map.get(chunk, :path),
      title: Map.get(chunk, :path) || Map.get(chunk, :context),
      purpose: Map.get(chunk, :context)
    }
  end

  @doc false
  def meaningful_tokens(query) when is_binary(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/u, trim: true)
    |> Enum.reject(&(String.length(&1) < 3 or MapSet.member?(@stopwords, &1)))
  end

  def meaningful_tokens(_), do: []
end
