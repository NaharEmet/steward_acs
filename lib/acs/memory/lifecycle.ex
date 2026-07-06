defmodule Acs.Memory.Lifecycle do
  @moduledoc """
  Retention policies and lifecycle rules for memory kinds.
  Defines three retention tiers: permanent, semi_permanent, temporal.
  Document retention: policies/processes/reference/spec are permanent,
  guidelines are semi-permanent (review every 90 days).
  """

  @typedoc "Retention tier for a memory entry"
  @type retention_tier :: :permanent | :semi_permanent | :temporal

  @retention_map %{
    observation: :permanent,
    learning: :permanent,
    warning: :permanent,
    pattern: :permanent,
    bug: :permanent,
    decision: :permanent,
    invariant: :permanent,
    axiom: :permanent,
    context: :semi_permanent,
    status: :semi_permanent,
    work_note: :temporal,
    activity: :temporal
  }

  @doc """
  Returns the retention tier for a given memory kind.
  """
  @spec tier_for(String.t()) :: retention_tier()
  def tier_for(kind) when is_binary(kind) do
    kind_atom = String.to_existing_atom(kind)
    Map.get(@retention_map, kind_atom, :permanent)
  rescue
    ArgumentError -> :permanent
  end

  @doc """
  Returns the TTL in days for a given memory kind.
  Only applies to temporal tiers. Returns nil for permanent/semi-permanent tiers.
  """
  @spec ttl_days(String.t()) :: integer() | nil
  def ttl_days("work_note") do
    work_note_ttl()
  end

  def ttl_days("activity") do
    activity_ttl()
  end

  def ttl_days(_kind), do: nil

  def work_note_ttl do
    env = System.get_env("WORK_NOTE_TTL_DAYS", "30")
    String.to_integer(env)
  end

  def activity_ttl do
    env = System.get_env("ACTIVITY_TTL_DAYS", "7")
    String.to_integer(env)
  end

  @doc """
  Returns all permanent memory kinds.
  """
  @spec permanent_kinds() :: [String.t()]
  def permanent_kinds do
    filter_kinds(:permanent)
  end

  @doc """
  Returns all semi-permanent memory kinds.
  """
  @spec semi_permanent_kinds() :: [String.t()]
  def semi_permanent_kinds do
    filter_kinds(:semi_permanent)
  end

  @doc """
  Returns all temporal memory kinds.
  """
  @spec temporal_kinds() :: [String.t()]
  def temporal_kinds do
    filter_kinds(:temporal)
  end

  defp filter_kinds(tier) do
    for {k, v} <- @retention_map, v == tier, do: Atom.to_string(k)
  end

  @doc """
  Returns days until review for a document type.
  Guidelines are reviewed every 90 days. Permanent types return nil.
  """
  @spec document_review_days(String.t()) :: integer() | nil
  def document_review_days("guideline"), do: 90
  def document_review_days(_), do: nil

  @doc """
  Checks if a memory has exceeded its TTL.
  Always returns false for permanent tier memories.
  """
  @spec expired?(map()) :: boolean()
  def expired?(memory)

  def expired?(%{kind: kind, created_at: created_at}) when is_binary(created_at) do
    case ttl_days(kind) do
      nil -> false
      days -> days_since(created_at) > days
    end
  end

  def expired?(_memory), do: false

  @doc """
  Checks if a memory with the given kind should auto-approve (skip auditor).
  Applies to: context, status, work_note, activity.
  """
  @spec auto_approve?(String.t()) :: boolean()
  def auto_approve?("context"), do: true
  def auto_approve?("status"), do: true
  def auto_approve?("work_note"), do: true
  def auto_approve?("activity"), do: true
  def auto_approve?(_), do: false

  defp days_since(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _} -> DateTime.diff(DateTime.utc_now(), dt, :day)
      {:error, _} -> 0
    end
  end
end
