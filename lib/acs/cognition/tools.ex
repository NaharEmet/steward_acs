defmodule Acs.Cognition.Tools do
  @moduledoc """
  MCP tool dispatchers for the Cognition Spec System.

  Implements 7 cognition tools that wrap the Cognition API
  (Entry, Loader, Search) and expose them as MCP-callable tools.

  ## Tools

    - `cognition_get` — Load a single spec entry by app and path
    - `cognition_search` — Search spec entries by query text
    - `cognition_propose` — Create or update a spec entry (set status to proposed)
    - `cognition_approve` — Approve a proposed spec entry
    - `cognition_reject` — Soft-reject a spec entry (reverts to under_review)
    - `cognition_list` — List spec entries, optionally filtered by app or status
    - `cognition_list_undocumented` — Find modules without specs
  """

  alias Acs.Cognition.Entry
  alias Acs.Cognition.Loader
  alias Acs.Cognition.Search

  require Logger

  @allowed_fields ~w(title purpose invariants workflows failure_modes state_machine constraints input output expected_transformation tags references verification_status)

  @doc """
  Dispatch a cognition tool by name with the given args map.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  def call_tool(name, args) do
    Logger.info("Cognition tool: #{name}")

    result =
      case name do
        "cognition_get" -> cognition_get(args)
        "cognition_search" -> cognition_search(args)
        "cognition_propose" -> cognition_propose(args)
        "cognition_approve" -> cognition_approve(args)
        "cognition_reject" -> cognition_reject(args)
        "cognition_list" -> cognition_list(args)
        "cognition_list_undocumented" -> cognition_list_undocumented(args)
        _ -> {:error, "Unknown cognition tool: #{name}"}
      end

    Logger.info("Cognition tool response: #{name} - #{response_summary(result)}")
    result
  end

  defp response_summary({:ok, result}) when is_map(result) do
    keys = Map.keys(result) |> Enum.join(", ")
    "ok (keys: #{keys})"
  end

  defp response_summary({:ok, result}), do: "ok: #{inspect(result)}"

  defp response_summary({:error, reason}), do: "error: #{inspect(reason)}"

  # ── cognition_get ──

  defp cognition_get(args) do
    with :ok <- require_params!(args, ~w(app path)) do
      case Loader.load(args["app"], args["path"]) do
        {:ok, entry} -> {:ok, Entry.to_map(entry)}
        {:error, :not_found} -> {:ok, nil}
        {:error, reason} -> {:error, "Failed to load spec: #{inspect(reason)}"}
      end
    end
  end

  # ── cognition_search ──

  defp cognition_search(args) do
    query = args["query"]

    if is_nil(query) or query == "" do
      {:error, "Missing required param: query"}
    else
      opts = build_search_opts(args)

      case Search.search(query, opts) do
        {:ok, entries} ->
          result = Enum.map(entries, &Entry.to_map/1)
          {:ok, result}

        {:error, reason} ->
          {:error, "Search failed: #{inspect(reason)}"}
      end
    end
  end

  defp build_search_opts(args) do
    opts = []

    opts =
      if args["status"] do
        Keyword.put(opts, :status, args["status"])
      else
        opts
      end

    opts =
      if args["app"] do
        Keyword.put(opts, :app, args["app"])
      else
        opts
      end

    opts
  end

  # ── cognition_propose ──

  defp cognition_propose(args) do
    with :ok <- require_params!(args, ~w(app path)) do
      attrs = args |> Map.drop(["app", "path"]) |> Map.take(@allowed_fields)
      title = attrs["title"] || ""

      # Check for duplicates/similars
      {:ok, dedup_warnings} = check_deduplication(args["app"], args["path"], title)

      case Loader.load(args["app"], args["path"]) do
        {:ok, existing_entry} ->
          result = propose_update(existing_entry, attrs)
          wrap_with_warnings(result, dedup_warnings)

        {:error, :not_found} ->
          result = propose_new(args["app"], args["path"], attrs)
          wrap_with_warnings(result, dedup_warnings)

        {:error, reason} ->
          {:error, "Failed to load existing spec: #{inspect(reason)}"}
      end
    end
  end

  defp wrap_with_warnings({:ok, spec_map}, warnings) when warnings != [],
    do: {:ok, Map.put(spec_map, :deduplication_warnings, warnings)}

  defp wrap_with_warnings(result, _warnings), do: result

  # ── Deduplication ──

  defp check_deduplication(app, path, title) do
    {:ok, all_entries} = Loader.load_all(app: app)

    same_space_warnings =
      all_entries
      |> Enum.filter(fn entry -> entry.id != path && same_path_prefix?(entry.id, path) end)
      |> Enum.map(fn entry ->
        %{
          type: "same_space",
          message: "Other specs exist in '#{path_prefix(path)}': #{Enum.map_join(all_same_space(entry.id, all_entries), ", ", &"#{&1}")}",
          conflicting_id: entry.id
        }
      end)
      |> Enum.uniq_by(fn %{conflicting_id: id} -> id end)

    similar_title_warnings =
      all_entries
      |> Enum.reject(fn entry -> entry.id == path || same_path_prefix?(entry.id, path) end)
      |> Enum.map(fn entry ->
        score = similarity_score(title, entry.title || "")
        %{entry: entry, score: score}
      end)
      |> Enum.filter(fn %{score: score} -> score >= 0.5 end)
      |> Enum.map(fn %{entry: entry, score: score} ->
        %{
          type: "similar_title",
          message: "Similar spec exists with title '#{entry.title}' (Jaccard: #{:erlang.float_to_binary(score, [{:decimals, 2}])}",
          conflicting_id: entry.id,
          score: score
        }
      end)

    warnings = same_space_warnings ++ similar_title_warnings
    {:ok, warnings}
  end

  defp path_prefix(path) do
    path |> String.split("/") |> Enum.drop(-1) |> Enum.join("/")
  end

  defp same_path_prefix?(id1, id2) do
    prefix1 = path_prefix(id1)
    prefix2 = path_prefix(id2)
    prefix1 != "" && prefix1 == prefix2
  end

  defp all_same_space(path, entries) do
    prefix = path_prefix(path)
    entries
    |> Enum.filter(fn e -> path_prefix(e.id) == prefix && e.id != path end)
    |> Enum.map(fn e -> e.id end)
  end

  defp similarity_score(title1, title2) do
    words1 =
      title1
      |> String.downcase()
      |> String.split(~r/\s+/)
      |> MapSet.new()

    words2 =
      title2
      |> String.downcase()
      |> String.split(~r/\s+/)
      |> MapSet.new()

    if MapSet.size(MapSet.union(words1, words2)) == 0,
      do: 0.0,
      else: MapSet.size(MapSet.intersection(words1, words2)) / MapSet.size(MapSet.union(words1, words2))
  end

  defp propose_update(existing_entry, attrs) do
    existing_map = Entry.to_map(existing_entry)
    current_version = existing_entry.version || 1

    merged =
      existing_map
      |> Map.merge(attrs)
      |> Map.put("status", "proposed")
      |> Map.put("version", current_version + 1)
      |> Map.put("parent_version", current_version)

    entry = Entry.from_map(merged)
    entry = %{entry | spec_hash: Entry.compute_spec_hash(entry)}

    case Loader.save(entry) do
      :ok -> {:ok, Entry.to_map(entry)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp propose_new(app, path, attrs) do
    new_args =
      %{"app" => app, "id" => path, "status" => "proposed"}
      |> Map.merge(attrs)

    entry = Entry.from_map(new_args)
    entry = %{entry | spec_hash: Entry.compute_spec_hash(entry)}

    case Loader.save(entry) do
      :ok -> {:ok, Entry.to_map(entry)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── cognition_approve ──

  defp cognition_approve(args) do
    with :ok <- require_params!(args, ~w(app path reviewer)) do
      case Loader.load(args["app"], args["path"]) do
        {:ok, entry} ->
          approve_entry(entry, args["reviewer"])

        {:error, :not_found} ->
          {:error, "Spec not found: #{args["app"]}/#{args["path"]}"}

        {:error, reason} ->
          {:error, "Failed to load spec: #{inspect(reason)}"}
      end
    end
  end

  defp approve_entry(entry, reviewer) do
    current_version = entry.version || 1

    entry = %{
      entry
      | status: "approved",
        approved_by: reviewer,
        version: current_version + 1,
        parent_version: current_version
    }

    entry = %{entry | spec_hash: Entry.compute_spec_hash(entry)}

    case Loader.save(entry) do
      :ok -> {:ok, Entry.to_map(entry)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── cognition_reject ──

  defp cognition_reject(args) do
    with :ok <- require_params!(args, ~w(app path)) do
      case Loader.load(args["app"], args["path"]) do
        {:ok, entry} ->
          reject_entry(entry)

        {:error, :not_found} ->
          {:error, "Spec not found: #{args["app"]}/#{args["path"]}"}

        {:error, reason} ->
          {:error, "Failed to load spec: #{inspect(reason)}"}
      end
    end
  end

  defp reject_entry(entry) do
    entry = %{entry | status: "under_review"}

    case Loader.save(entry) do
      :ok -> {:ok, Entry.to_map(entry)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── cognition_list ──

  defp cognition_list(args) do
    app_filter = args["app"]
    status_filter = args["status"]

    {:ok, entries} = Loader.load_all(app: app_filter)
    filtered = Enum.filter(entries, fn entry -> matches_status?(entry.status, status_filter) end)
    summaries = Enum.map(filtered, &entry_summary/1)
    {:ok, %{entries: summaries, count: length(summaries)}}
  end

  defp matches_status?(_entry_status, nil), do: true
  defp matches_status?(_entry_status, ""), do: true
  defp matches_status?(entry_status, filter), do: entry_status == filter

  defp entry_summary(entry) do
    %{
      id: entry.id,
      app: entry.app,
      status: entry.status,
      title: entry.title,
      purpose: entry.purpose,
      verification_status: entry.verification_status
    }
  end

  # ── cognition_list_undocumented ──

  defp cognition_list_undocumented(args) do
    app_filter = args["app"]
    lib_dir = default_lib_dir()

    results = Loader.find_undocumented(lib_dir, app: app_filter)
    {:ok, %{undocumented: results, count: length(results)}}
  end

  defp require_params!(args, required) do
    Enum.reduce_while(required, :ok, fn key, _acc ->
      case args[key] do
        value when is_nil(value) or value == "" ->
          {:halt, {:error, "Missing required param: #{key}"}}

        _ ->
          {:cont, :ok}
      end
    end)
  end

  defp default_lib_dir do
    Path.join(Application.app_dir(:steward_acs), "lib")
  end
end
