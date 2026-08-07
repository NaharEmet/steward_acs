defmodule Acs.Governance.Status do
  @moduledoc """
  Shared governance lifecycle for human-reviewed knowledge.

  Primary statuses are intentionally small and consistent across memories,
  skills, and documents. Domain-specific operational or audit states remain
  owned by their respective stores.
  """

  @primary ~w(proposed approved rejected deprecated)
  @transitions %{
    "proposed" => ~w(approved rejected),
    "approved" => ~w(deprecated),
    "rejected" => [],
    "deprecated" => []
  }

  @doc "Returns the shared human-governance statuses in display order."
  def primary_statuses, do: @primary

  @doc "Returns true when status is part of the shared governance lifecycle."
  def primary?(status), do: status in @primary

  @doc "Returns the statuses a record may move to from its current status."
  def allowed_transitions(nil), do: ["proposed"]
  def allowed_transitions(status), do: Map.get(@transitions, status, [])

  @doc "Checks whether a governance transition is valid. Repeating a status is idempotent."
  def transition_allowed?(from, to) when from == to and to in @primary, do: true
  def transition_allowed?(from, to), do: to in allowed_transitions(from)
end
