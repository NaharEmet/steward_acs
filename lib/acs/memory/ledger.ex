defmodule Acs.Memory.Ledger do
  @moduledoc """
  Append-only, database-canonical memory storage used in multi-tenant mode.

  A command atomically appends a tenant commit and full memory revision, moves
  the logical memory head, and updates the current-state query projection.
  Commit and revision rows are protected from UPDATE/DELETE by database
  triggers installed by the ledger migration.
  """

  import Ecto.Query

  alias Acs.Memory.{Commit, CompanyMemory, Revision}
  alias Acs.Orgs.Organization
  alias Acs.Repo

  @type actor :: %{
          required(:type) => String.t(),
          required(:id) => String.t(),
          optional(:display) => String.t()
        }

  @doc "Append a create or revise snapshot and update the current projection."
  def save(%Acs.Memory{} = memory, opts \\ []) do
    org = memory.org || Keyword.get(opts, :org) || Acs.Org.current()
    actor = normalize_actor(Keyword.get(opts, :actor), memory.created_by)
    source = Keyword.get(opts, :source, "system") |> to_string()
    message = Keyword.get(opts, :message, "Save memory #{memory.id}")
    expected_head = Keyword.get(opts, :expected_head_revision_id)
    request_id = Keyword.get(opts, :request_id)

    Repo.transaction(fn ->
      organization =
        Repo.get_by(Organization, slug: org) ||
          Repo.rollback({:organization_not_found, org})

      lock_tenant_ledger!(organization.id)

      company = get_or_create_company!(organization.id, memory.id)
      parent = get_head_revision(company)

      if parent && is_nil(expected_head) do
        Repo.rollback(:expected_head_revision_required)
      end

      verify_expected_head!(parent, expected_head)

      operation = Keyword.get(opts, :operation, if(parent, do: "revise", else: "create"))
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      memory = normalize_timestamps(memory, parent, now)
      snapshot_json = memory |> Acs.Memory.to_yaml_map() |> Jason.encode!()
      content_hash = canonical_hash(Acs.Memory.to_yaml_map(memory))
      revision_id = Ecto.UUID.generate()
      revision_number = if(parent, do: parent.revision_number + 1, else: 1)
      parent_revision_hash = parent && parent.revision_hash
      metadata_json = Jason.encode!(Keyword.get(opts, :metadata, %{}))

      revision_hash =
        canonical_hash(%{
          organization_id: organization.id,
          memory_id: company.id,
          revision_number: revision_number,
          parent_revision_hash: parent_revision_hash,
          operation: to_string(operation),
          content_hash: content_hash,
          metadata_json: metadata_json
        })

      latest_commit = latest_commit(organization.id)
      sequence = if(latest_commit, do: latest_commit.sequence + 1, else: 1)
      commit_id = Ecto.UUID.generate()

      commit_attrs = %{
        id: commit_id,
        organization_id: organization.id,
        sequence: sequence,
        parent_commit_id: latest_commit && latest_commit.id,
        parent_commit_hash: latest_commit && latest_commit.commit_hash,
        actor_type: actor.type,
        actor_id: actor.id,
        actor_display: Map.get(actor, :display),
        message: message,
        source: source,
        request_id: request_id,
        committed_at: now,
        commit_hash:
          commit_hash(%{
            organization_id: organization.id,
            sequence: sequence,
            parent_hash: latest_commit && latest_commit.commit_hash,
            revision_id: revision_id,
            revision_hash: revision_hash,
            actor: actor,
            message: message,
            source: source,
            committed_at: now
          })
      }

      commit = %Commit{} |> Commit.changeset(commit_attrs) |> Repo.insert!()

      revision_attrs = %{
        id: revision_id,
        organization_id: organization.id,
        memory_id: company.id,
        revision_number: revision_number,
        parent_revision_id: parent && parent.id,
        parent_revision_hash: parent_revision_hash,
        commit_id: commit.id,
        operation: to_string(operation),
        snapshot_json: snapshot_json,
        metadata_json: metadata_json,
        content_hash: content_hash,
        revision_hash: revision_hash,
        inserted_at: now
      }

      revision = %Revision{} |> Revision.changeset(revision_attrs) |> Repo.insert!()

      company
      |> CompanyMemory.changeset(%{head_revision_id: revision.id})
      |> Repo.update!()

      case Acs.Memory.Indexer.upsert_memory(memory,
             broadcast: false,
             company_memory_id: company.id,
             head_revision_id: revision.id
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback({:projection_failed, reason})
      end

      %{memory: memory, revision: revision, commit: commit}
    end)
    |> case do
      {:ok, result} ->
        Acs.Memory.Indexer.broadcast_memory_updated()
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error ->
      {:error, {:ledger_write_failed, Exception.message(error)}}
  end

  @doc "Import legacy projection rows that do not yet have a ledger head."
  def backfill_projection do
    rows =
      Repo.all(
        from m in Acs.Memory.Schema,
          where: is_nil(m.company_memory_id) or is_nil(m.head_revision_id),
          order_by: [asc: m.org, asc: m.id]
      )

    Enum.reduce_while(rows, {:ok, 0}, fn row, {:ok, count} ->
      memory = row |> Acs.Memory.Indexer.schema_to_memory_attrs() |> Acs.Memory.new()

      case save(memory,
             operation: "import",
             actor: %{type: "importer", id: "legacy_projection_backfill"},
             source: "migration",
             message: "Import legacy memory #{memory.id}",
             metadata: %{legacy_storage_id: row.id}
           ) do
        {:ok, _} ->
          {:cont, {:ok, count + 1}}

        {:error, reason} ->
          {:halt, {:error, %{memory_id: row.id, reason: reason, imported: count}}}
      end
    end)
  end

  @doc "Return immutable revisions oldest-first for an org-scoped public ID."
  def history(public_id, org \\ Acs.Org.current()) do
    with %Organization{id: organization_id} <- Repo.get_by(Organization, slug: org),
         %CompanyMemory{id: memory_id} <-
           Repo.get_by(CompanyMemory, organization_id: organization_id, public_id: public_id) do
      Repo.all(
        from r in Revision,
          where: r.organization_id == ^organization_id and r.memory_id == ^memory_id,
          order_by: [asc: r.revision_number]
      )
    else
      _ -> []
    end
  end

  @doc "Decode a revision's full immutable memory snapshot."
  def snapshot(%Revision{snapshot_json: json}), do: Jason.decode(json)

  @doc "Calculate changed top-level fields between two immutable revisions."
  def diff(%Revision{} = from, %Revision{} = to) do
    with {:ok, from_snapshot} <- snapshot(from),
         {:ok, to_snapshot} <- snapshot(to) do
      keys = (Map.keys(from_snapshot) ++ Map.keys(to_snapshot)) |> Enum.uniq() |> Enum.sort()

      {:ok,
       Enum.reduce(keys, %{}, fn key, changes ->
         old = Map.get(from_snapshot, key)
         new = Map.get(to_snapshot, key)
         if old == new, do: changes, else: Map.put(changes, key, %{from: old, to: new})
       end)}
    end
  end

  @doc "Restore a historical snapshot by appending a new revision."
  def restore(public_id, revision_id, opts \\ []) do
    org = Keyword.get(opts, :org, Acs.Org.current())

    with %Organization{id: organization_id} <- Repo.get_by(Organization, slug: org),
         %CompanyMemory{id: memory_id} = company <-
           Repo.get_by(CompanyMemory, organization_id: organization_id, public_id: public_id),
         %Revision{memory_id: ^memory_id, organization_id: ^organization_id} = revision <-
           Repo.get(Revision, revision_id),
         {:ok, attrs} <- snapshot(revision) do
      attrs
      |> Acs.Memory.new()
      |> save(
        opts
        |> Keyword.put_new(:expected_head_revision_id, company.head_revision_id)
        |> Keyword.put(:operation, "restore")
        |> Keyword.put_new(:message, "Restore memory #{public_id} from revision #{revision_id}")
        |> Keyword.put(:metadata, %{restored_from_revision_id: revision_id})
      )
    else
      nil -> {:error, :not_found}
      _ -> {:error, :revision_not_accessible}
    end
  end

  @doc "Verify revision and commit hashes and parent links for one tenant."
  def verify(org \\ Acs.Org.current()) do
    with %Organization{id: organization_id} <- Repo.get_by(Organization, slug: org) do
      commits =
        Repo.all(
          from c in Commit,
            where: c.organization_id == ^organization_id,
            order_by: [asc: c.sequence]
        )

      revisions = Repo.all(from r in Revision, where: r.organization_id == ^organization_id)
      revisions_by_commit = Map.new(revisions, &{&1.commit_id, &1})
      revisions_by_id = Map.new(revisions, &{&1.id, &1})

      Enum.reduce_while(commits, {:ok, nil}, fn commit, {:ok, previous} ->
        revision = Map.get(revisions_by_commit, commit.id)
        parent_revision = revision && Map.get(revisions_by_id, revision.parent_revision_id)

        expected =
          revision &&
            commit_hash(%{
              organization_id: organization_id,
              sequence: commit.sequence,
              parent_hash: previous && previous.commit_hash,
              revision_id: revision.id,
              revision_hash: revision.revision_hash,
              actor: %{
                type: commit.actor_type,
                id: commit.actor_id,
                display: commit.actor_display
              },
              message: commit.message,
              source: commit.source,
              committed_at: commit.committed_at
            })

        valid_snapshot? =
          case revision && Jason.decode(revision.snapshot_json) do
            {:ok, snapshot} -> canonical_hash(snapshot) == revision.content_hash
            _ -> false
          end

        expected_revision_hash =
          revision &&
            canonical_hash(%{
              organization_id: revision.organization_id,
              memory_id: revision.memory_id,
              revision_number: revision.revision_number,
              parent_revision_hash: revision.parent_revision_hash,
              operation: revision.operation,
              content_hash: revision.content_hash,
              metadata_json: revision.metadata_json
            })

        valid_revision_parent? =
          if revision && revision.revision_number == 1 do
            is_nil(revision.parent_revision_id) and is_nil(revision.parent_revision_hash)
          else
            revision && parent_revision && parent_revision.memory_id == revision.memory_id &&
              parent_revision.revision_number + 1 == revision.revision_number &&
              parent_revision.revision_hash == revision.parent_revision_hash
          end

        if revision && valid_snapshot? && valid_revision_parent? &&
             expected_revision_hash == revision.revision_hash && expected == commit.commit_hash &&
             commit.sequence == if(previous, do: previous.sequence + 1, else: 1) &&
             commit.parent_commit_id == (previous && previous.id) &&
             commit.parent_commit_hash == (previous && previous.commit_hash) do
          {:cont, {:ok, commit}}
        else
          {:halt, {:error, {:invalid_commit, commit.id}}}
        end
      end)
      |> case do
        {:ok, _last} ->
          if length(commits) == length(revisions) and heads_valid?(organization_id),
            do: :ok,
            else: {:error, :orphan_or_invalid_head}

        error ->
          error
      end
    else
      nil -> {:error, {:organization_not_found, org}}
    end
  end

  defp heads_valid?(organization_id) do
    Repo.all(from m in CompanyMemory, where: m.organization_id == ^organization_id)
    |> Enum.all?(fn company ->
      revision = Repo.get(Revision, company.head_revision_id)
      projection = Repo.get_by(Acs.Memory.Schema, company_memory_id: company.id)

      revision && projection && revision.organization_id == organization_id &&
        revision.memory_id == company.id && projection.head_revision_id == revision.id
    end)
  end

  defp get_or_create_company!(organization_id, public_id) do
    query =
      from m in CompanyMemory,
        where: m.organization_id == ^organization_id and m.public_id == ^public_id

    query = if postgres?(), do: from(m in query, lock: "FOR UPDATE"), else: query

    Repo.one(query) ||
      %CompanyMemory{}
      |> CompanyMemory.changeset(%{
        id: Ecto.UUID.generate(),
        organization_id: organization_id,
        public_id: public_id,
        created_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()
  end

  defp get_head_revision(%CompanyMemory{head_revision_id: nil}), do: nil
  defp get_head_revision(%CompanyMemory{head_revision_id: id}), do: Repo.get!(Revision, id)

  defp latest_commit(organization_id) do
    Repo.one(
      from c in Commit,
        where: c.organization_id == ^organization_id,
        order_by: [desc: c.sequence],
        limit: 1
    )
  end

  defp verify_expected_head!(_parent, nil), do: :ok

  defp verify_expected_head!(%Revision{id: expected}, expected), do: :ok

  defp verify_expected_head!(parent, expected) do
    Repo.rollback({:conflict, %{expected_head: expected, actual_head: parent && parent.id}})
  end

  defp lock_tenant_ledger!(organization_id) do
    if postgres?() do
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1)", [organization_id])
    end

    :ok
  end

  defp normalize_timestamps(memory, parent, now) do
    created_at =
      if parent do
        case snapshot(parent) do
          {:ok, %{"created_at" => value}} -> value
          _ -> memory.created_at
        end
      else
        memory.created_at || DateTime.to_iso8601(now)
      end

    %{memory | created_at: created_at, updated_at: DateTime.to_iso8601(now)}
  end

  defp normalize_actor(nil, created_by), do: normalize_actor(created_by, nil)

  defp normalize_actor(actor, _created_by) when is_map(actor) do
    %{
      type: actor[:type] || actor["type"] || "agent",
      id: to_string(actor[:id] || actor["id"] || "unknown"),
      display: actor[:display] || actor["display"] || actor[:name] || actor["name"]
    }
  end

  defp normalize_actor(_actor, _created_by), do: %{type: "system", id: "unknown", display: nil}

  defp canonical_hash(value) do
    value
    |> canonical_term()
    |> Jason.encode!()
    |> sha256()
  end

  defp canonical_term(value) when is_map(value) do
    [
      "map"
      | value
        |> Enum.map(fn {key, item} -> [to_string(key), canonical_term(item)] end)
        |> Enum.sort()
    ]
  end

  defp canonical_term(value) when is_list(value),
    do: ["list" | Enum.map(value, &canonical_term/1)]

  defp canonical_term(value), do: value

  defp commit_hash(fields) do
    fields
    |> Map.update!(:committed_at, &DateTime.to_iso8601/1)
    |> canonical_hash()
  end

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp postgres?, do: to_string(Acs.Repo.__adapter__()) == "Elixir.Ecto.Adapters.Postgres"
end
