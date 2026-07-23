defmodule Acs.Specs.Tools do
  require Logger

  @moduledoc """
  MCP tool dispatchers for the Specs / Document System.

  Stores module specs AND shareable documents (project docs, marketing copy,
  knowledge files, deliverables). See `priv/prompts/specs/instructions.md`.
  """

  alias Acs.Abac
  alias Acs.Specs.Entry
  alias Acs.Specs.Loader
  alias Acs.Specs.Search

  require Logger

  @allowed_fields ~w(title purpose invariants workflows failure_modes state_machine constraints input output expected_transformation tags references verification_status document_type content team project visibility source)

  @doc """
  Dispatch a cognition tool by name with the given args map.

  Returns `{:ok, result}` on success or `{:error, reason}` on failure.
  """
  def call_tool(name, args) do
    Logger.info("Specs tool: #{name}")

    result =
      case name do
        "specs_get" -> specs_get(args)
        "query_specs" -> query_specs(args)
        "specs_propose" -> specs_propose(args)
        "specs_approve" -> specs_approve(args)
        "specs_reject" -> specs_reject(args)
        _ -> {:error, "Unknown specs tool: #{name}"}
      end

    Logger.info("Specs tool response: #{name} - #{response_summary(result)}")
    result
  end

  defp response_summary({:ok, result}) when is_map(result) do
    keys = Map.keys(result) |> Enum.join(", ")
    "ok (keys: #{keys})"
  end

  defp response_summary({:ok, result}), do: "ok: #{inspect(result)}"

  defp response_summary({:error, reason}), do: "error: #{inspect(reason)}"

  # ── specs_get ──

  defp specs_get(args) do
    ctx = Abac.from_args(args)

    with :ok <- require_params!(args, ~w(app path)) do
      case Loader.load(args["app"], args["path"]) do
        {:ok, entry} ->
          if Abac.visible?(ctx, entry), do: {:ok, Entry.to_map(entry)}, else: {:ok, nil}

        {:error, :not_found} ->
          {:ok, nil}

        {:error, reason} ->
          {:error, "Failed to load spec: #{inspect(reason)}"}
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

  # ── specs_propose ──

  defp specs_propose(args) do
    ctx = Abac.from_args(args)

    with :ok <- require_params!(args, ~w(app path)),
         attrs = args |> Map.drop(["app", "path"]) |> Map.take(@allowed_fields),
         :ok <- Abac.validate_write(ctx, attrs),
         :ok <- ensure_entry_writable(ctx, args["app"], args["path"]) do
      title = attrs["title"] || ""

      # Check for duplicates/similars
      {:ok, dedup_warnings} = check_deduplication(args["app"], args["path"], title)

      result =
        case Loader.load(args["app"], args["path"]) do
          {:ok, existing_entry} ->
            result = propose_update(existing_entry, attrs)
            maybe_generate_embeddings_async(args["app"], args["path"])
            result

          {:error, :not_found} ->
            result = propose_new(args["app"], args["path"], attrs)
            maybe_generate_embeddings_async(args["app"], args["path"])
            result

          {:error, reason} ->
            {:error, "Failed to load existing spec: #{inspect(reason)}"}
        end

      wrap_with_warnings(result, dedup_warnings)
    end
  end

  defp maybe_generate_embeddings_async(app, path) do
    Task.start(fn ->
      case Loader.load(app, path) do
        {:ok, entry} ->
          chunks = Acs.Specs.VectorSearch.chunk_entry(entry)

          Enum.each(chunks, fn chunk ->
            case Acs.Memory.Embedding.embed_text(chunk.text) do
              {:ok, embedding} ->
                Acs.Specs.VectorSearch.upsert_chunk(
                  chunk.id,
                  chunk.app,
                  chunk.path,
                  chunk.chunk_index,
                  chunk.source,
                  chunk.content,
                  embedding
                )

              {:error, reason} ->
                Logger.warning("[Tools] Failed to embed spec #{app}/#{path}: #{reason}")
            end
          end)

        {:error, _} ->
          :ok
      end
    end)
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
          message:
            "Other specs exist in '#{path_prefix(path)}': #{Enum.map_join(all_same_space(entry.id, all_entries), ", ", &"#{&1}")}",
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
          message:
            "Similar spec exists with title '#{entry.title}' (Jaccard: #{:erlang.float_to_binary(score, [{:decimals, 2}])}",
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
      else:
        MapSet.size(MapSet.intersection(words1, words2)) /
          MapSet.size(MapSet.union(words1, words2))
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

  # ── specs_approve ──

  defp specs_approve(args) do
    ctx = Abac.from_args(args)

    with :ok <- require_params!(args, ~w(app path reviewer)) do
      case Loader.load(args["app"], args["path"]) do
        {:ok, entry} ->
          if Abac.visible?(ctx, entry) do
            approve_entry(entry, args["reviewer"])
          else
            {:error, "Access denied"}
          end

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

  # ── specs_reject ──

  defp specs_reject(args) do
    ctx = Abac.from_args(args)

    with :ok <- require_params!(args, ~w(app path)) do
      case Loader.load(args["app"], args["path"]) do
        {:ok, entry} ->
          if Abac.visible?(ctx, entry) do
            reject_entry(entry)
          else
            {:error, "Access denied"}
          end

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

  # ── query_specs (unified: search / list / undocumented) ──

  defp query_specs(args) do
    query = args["query"]
    undocumented = args["undocumented"] || args["include_undocumented"]
    ctx = Abac.from_args(args)

    with :ok <- validate_app_filter(args["app"]) do
      cond do
        undocumented ->
          app_filter = args["app"]
          lib_dir = default_lib_dir()
          results = Loader.find_undocumented(lib_dir, app: app_filter)
          {:ok, %{undocumented: results, count: length(results)}}

        query && query != "" ->
          opts = build_search_opts(args)
          mode = args["mode"] || "hybrid"
          opts = Keyword.put(opts, :mode, mode)

          case Search.search(query, opts) do
            {:ok, entries} ->
              result =
                entries
                |> Abac.filter(ctx)
                |> Enum.map(fn
                  %{__rag_chunk: true} = chunk ->
                    chunk

                  entry ->
                    Entry.to_map(entry)
                end)

              {:ok, %{specs: result, count: length(result), mode: mode}}

            {:error, reason} ->
              {:error, "Search failed: #{inspect(reason)}"}
          end

        true ->
          app_filter = args["app"]
          status_filter = args["status"]

          case Loader.load_all(app: app_filter) do
            {:ok, entries} ->
              filtered =
                entries
                |> Abac.filter(ctx)
                |> Enum.filter(fn entry -> matches_status?(entry.status, status_filter) end)

              summaries = Enum.map(filtered, &entry_summary/1)
              {:ok, %{specs: summaries, count: length(summaries)}}

            {:error, reason} ->
              {:error, "Failed to list specs: #{inspect(reason)}"}
          end
      end
    end
  end

  defp validate_app_filter(nil), do: :ok

  defp validate_app_filter(app) do
    case Loader.validate_app(app) do
      :ok -> :ok
      {:error, :invalid_app} -> {:error, "Invalid app identifier"}
    end
  end

  defp ensure_entry_writable(ctx, app, path) do
    case Loader.load(app, path) do
      {:ok, entry} ->
        if Abac.visible?(ctx, entry), do: :ok, else: {:error, "Access denied"}

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, "Failed to load existing spec: #{inspect(reason)}"}
    end
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
