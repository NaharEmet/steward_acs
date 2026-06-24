defmodule Anantha.CRM.CrmStats do
  @moduledoc """
  Aggregation queries for CRM data visualization and dashboard.

  Provides global (cross-org) aggregate statistics from the CRM tables:
  - CrmEntitySnapshot — versioned entity state snapshots
  - CrmIdentity — CRM-to-Actor identity links
  - CrmRelationship — cross-entity relationships
  """

  import Ecto.Query
  alias Anantha.Repo

  alias Anantha.CRM.CrmEntitySnapshot
  alias Anantha.CRM.CrmRelationship
  alias Anantha.CRM.CrmIdentity

  @doc """
  Returns all CRM stats for the global dashboard.
  Aggregated across all orgs.
  """
  def global_stats do
    %{
      total_active_entities: count_active_entities(),
      total_snapshots: count_snapshots(),
      total_entities_all_time: count_all_entities(),
      entities_by_type: entities_by_object_type(),
      version_health: version_health(),
      total_identities: count_identities(),
      identities_by_match_type: identities_by_match_type(),
      total_relationships: count_relationships(),
      relationships_by_predicate: relationships_by_predicate(),
      recent_snapshots: recent_snapshot_activity(20),
      org_stats: org_entity_stats()
    }
  end

  @doc """
  Returns CRM stats scoped to a specific org.
  """
  def org_stats(org_id) do
    %{
      total_active_entities: count_active_entities(org_id),
      total_snapshots: count_snapshots(org_id),
      entities_by_type: entities_by_object_type(org_id),
      version_health: version_health(org_id),
      total_identities: count_identities(org_id),
      identities_by_match_type: identities_by_match_type(org_id),
      total_relationships: count_relationships(org_id),
      relationships_by_predicate: relationships_by_predicate(org_id)
    }
  end

  # ============================================================================
  # Entity Snapshot Stats
  # ============================================================================

  defp count_active_entities(org_id \\ nil)

  defp count_active_entities(nil) do
    Repo.one(
      from s in CrmEntitySnapshot,
        where: is_nil(s.valid_to),
        select: count(s.entity_id, :distinct)
    ) || 0
  end

  defp count_active_entities(org_id) do
    Repo.one(
      from s in CrmEntitySnapshot,
        where: s.org_id == ^org_id and is_nil(s.valid_to),
        select: count(s.entity_id, :distinct)
    ) || 0
  end

  defp count_all_entities(org_id \\ nil)

  defp count_all_entities(nil) do
    Repo.one(from s in CrmEntitySnapshot, select: count(s.entity_id, :distinct)) || 0
  end

  defp count_all_entities(org_id) do
    Repo.one(
      from s in CrmEntitySnapshot,
        where: s.org_id == ^org_id,
        select: count(s.entity_id, :distinct)
    ) || 0
  end

  defp count_snapshots(org_id \\ nil)

  defp count_snapshots(nil) do
    Repo.one(from s in CrmEntitySnapshot, select: count(s.id)) || 0
  end

  defp count_snapshots(org_id) do
    Repo.one(
      from s in CrmEntitySnapshot,
        where: s.org_id == ^org_id,
        select: count(s.id)
    ) || 0
  end

  defp entities_by_object_type(org_id \\ nil) do
    base = from s in CrmEntitySnapshot, where: is_nil(s.valid_to)

    base =
      if org_id,
        do: where(base, [s], s.org_id == ^org_id),
        else: base

    Repo.all(
      from s in base,
        group_by: s.object_type,
        select: %{object_type: s.object_type, count: count(s.entity_id)}
    )
  end

  defp version_health(org_id \\ nil) do
    base = from(s in CrmEntitySnapshot)

    base =
      if org_id,
        do: where(base, [s], s.org_id == ^org_id),
        else: base

    sub =
      from s in base,
        group_by: s.entity_id,
        select: %{entity_id: s.entity_id, version_count: count(s.id)}

    single =
      Repo.one(
        from s in subquery(sub),
          where: s.version_count == 1,
          select: count(s.entity_id)
      ) || 0

    multi =
      Repo.one(
        from s in subquery(sub),
          where: s.version_count > 1,
          select: count(s.entity_id)
      ) || 0

    %{single_version: single, multi_version: multi}
  end

  defp recent_snapshot_activity(limit) do
    Repo.all(
      from s in CrmEntitySnapshot,
        order_by: [desc: s.inserted_at],
        limit: ^limit,
        select: %{
          entity_id: s.entity_id,
          object_type: s.object_type,
          source: s.source,
          version: s.version,
          inserted_at: s.inserted_at,
          has_changes: not is_nil(s.change_summary)
        }
    )
  end

  # ============================================================================
  # Identity Stats
  # ============================================================================

  defp count_identities(org_id \\ nil)

  defp count_identities(nil) do
    Repo.one(from i in CrmIdentity, select: count(i.id)) || 0
  end

  defp count_identities(org_id) do
    Repo.one(
      from i in CrmIdentity,
        where: i.org_id == ^org_id,
        select: count(i.id)
    ) || 0
  end

  defp identities_by_match_type(org_id \\ nil) do
    base = CrmIdentity

    base =
      if org_id,
        do: from(i in base, where: i.org_id == ^org_id),
        else: base

    Repo.all(
      from i in base,
        group_by: i.match_type,
        select: %{match_type: i.match_type, count: count(i.id)}
    )
  end

  # ============================================================================
  # Relationship Stats
  # ============================================================================

  defp count_relationships(org_id \\ nil)

  defp count_relationships(nil) do
    Repo.one(from r in CrmRelationship, select: count(r.id)) || 0
  end

  defp count_relationships(org_id) do
    Repo.one(
      from r in CrmRelationship,
        where: r.org_id == ^org_id,
        select: count(r.id)
    ) || 0
  end

  defp relationships_by_predicate(org_id \\ nil) do
    base = CrmRelationship

    base =
      if org_id,
        do: from(r in base, where: r.org_id == ^org_id),
        else: base

    Repo.all(
      from r in base,
        group_by: r.predicate,
        select: %{predicate: r.predicate, count: count(r.id)}
    )
  end

  # ============================================================================
  # Per-Org Breakdown
  # ============================================================================

  defp org_entity_stats do
    Repo.all(
      from s in CrmEntitySnapshot,
        where: is_nil(s.valid_to),
        group_by: [s.org_id, s.object_type],
        select: %{org_id: s.org_id, object_type: s.object_type, count: count(s.entity_id)}
    )
  end
end
