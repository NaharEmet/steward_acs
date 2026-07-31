defmodule Acs.Memory.Store do
  @moduledoc """
  Canonical persistence boundary for memories.

  Single-tenant deployments preserve the file-backed workflow. Multi-tenant
  deployments never write memory files and use `Acs.Memory.Ledger` as the
  canonical append-only store.
  """

  alias Acs.Memory.{Indexer, Ledger, Loader}

  @doc "Persist a memory through the backend selected by deployment mode."
  def save(%Acs.Memory{} = memory, opts \\ []) do
    if Acs.Org.multi_tenant?() do
      org = Acs.Org.current()

      if memory.org not in [nil, org] do
        {:error, :tenant_mismatch}
      else
        memory = %{memory | org: org}

        opts =
          case Indexer.get_memory(memory.id, org) do
            %{head_revision_id: head} when is_binary(head) ->
              Keyword.put_new(opts, :expected_head_revision_id, head)

            _ ->
              opts
          end

        Ledger.save(memory, Keyword.put(opts, :org, org))
      end
    else
      with :ok <- Loader.save(memory),
           {:ok, _} <- Indexer.upsert_memory(memory) do
        {:ok, %{memory: memory, revision: nil, commit: nil}}
      end
    end
  end

  @doc "Create an immutable status transition (or update the canonical file locally)."
  def transition(memory_id, status, opts \\ [])
      when status in ~w(proposed approved rejected stale deprecated archived parse_error) do
    org = Keyword.get(opts, :org, Acs.Org.current())

    with %Acs.Memory.Schema{} = schema <-
           Indexer.get_memory(memory_id, org) || {:error, :not_found},
         :ok <- require_ledger_head(schema) do
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      reason = Keyword.get(opts, :reason)

      status_attrs =
        case status do
          "approved" ->
            %{
              "status" => status,
              "verification" => %{
                "status" => status,
                "approved_by" => actor_id(opts),
                "approved_at" => now
              }
            }

          "rejected" ->
            %{
              "status" => status,
              "verification" => %{
                "status" => status,
                "rejected_by" => actor_id(opts),
                "rejected_at" => now
              }
            }

          value when value in ~w(stale deprecated archived) ->
            %{
              "status" => value,
              "revalidation" => %{
                "reason" => reason || "No reason provided",
                "marked_at" => now
              }
            }

          value ->
            %{"status" => value}
        end

      memory =
        schema
        |> Indexer.schema_to_memory_attrs()
        |> Map.merge(status_attrs)
        |> Acs.Memory.new()

      save(
        memory,
        opts
        |> put_expected_head(schema)
        |> Keyword.put(:operation, "transition")
        |> Keyword.put_new(:message, "Transition memory #{memory_id} to #{status}")
        |> Keyword.update(
          :metadata,
          %{status: status, reason: reason},
          &Map.merge(&1, %{status: status, reason: reason})
        )
      )
    end
  end

  @doc "Create a revision containing a title/content patch."
  def revise(memory_id, patch, opts \\ []) when is_map(patch) do
    org = Keyword.get(opts, :org, Acs.Org.current())

    with %Acs.Memory.Schema{} = schema <-
           Indexer.get_memory(memory_id, org) || {:error, :not_found},
         :ok <- require_ledger_head(schema) do
      allowed = ~w(title content summary importance tags triggers failure_modes related_memories)a

      patch =
        patch
        |> Enum.filter(fn {key, _value} -> normalize_key(key) in allowed end)
        |> Map.new(fn {key, value} -> {Atom.to_string(normalize_key(key)), value} end)

      memory =
        schema
        |> Indexer.schema_to_memory_attrs()
        |> Map.merge(patch)
        |> Acs.Memory.new()

      save(
        memory,
        opts
        |> put_expected_head(schema)
        |> Keyword.put(:operation, "revise")
        |> Keyword.put_new(:message, "Revise memory #{memory_id}")
        |> Keyword.update(
          :metadata,
          %{changed_fields: Map.keys(patch)},
          &Map.put(&1, :changed_fields, Map.keys(patch))
        )
      )
    end
  end

  def history(memory_id, org \\ Acs.Org.current()) do
    if Acs.Org.multi_tenant?() and org != Acs.Org.current(),
      do: [],
      else: Ledger.history(memory_id, org)
  end

  def diff(from_revision, to_revision), do: Ledger.diff(from_revision, to_revision)

  def restore(memory_id, revision_id, opts \\ []) do
    if Acs.Org.multi_tenant?() do
      Ledger.restore(memory_id, revision_id, opts)
    else
      {:error, :history_not_available_in_file_mode}
    end
  end

  def verify(org \\ Acs.Org.current()), do: Ledger.verify(org)

  defp require_ledger_head(%{head_revision_id: nil}) do
    if Acs.Org.multi_tenant?(), do: {:error, :ledger_backfill_required}, else: :ok
  end

  defp require_ledger_head(_schema), do: :ok

  defp put_expected_head(opts, schema) do
    if Acs.Org.multi_tenant?(),
      do: Keyword.put_new(opts, :expected_head_revision_id, schema.head_revision_id),
      else: opts
  end

  defp actor_id(opts) do
    actor = Keyword.get(opts, :actor, %{})
    actor[:id] || actor["id"] || "unknown"
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    case key do
      "title" -> :title
      "content" -> :content
      "summary" -> :summary
      "importance" -> :importance
      "tags" -> :tags
      "triggers" -> :triggers
      "failure_modes" -> :failure_modes
      "related_memories" -> :related_memories
      _ -> :unsupported
    end
  end

  defp normalize_key(_), do: :unsupported
end
