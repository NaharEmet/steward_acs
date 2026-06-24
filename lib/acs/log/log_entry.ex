defmodule Acs.Log.LogEntry do
  @moduledoc """
  Schema for persistent log entries stored in the database.

  Log entries are dual-written to both ETS (fast recent queries) and
  the `log_entries` table (persistent storage across restarts).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "log_entries" do
    field :timestamp, :utc_datetime_usec
    field :level, :string
    field :service, :string
    field :component, :string
    field :message, :string
    field :metadata, :map, default: %{}
    field :workflow_id, :string
    field :execution_id, :string
    field :cluster, :string

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds a changeset for validating log entry attributes.
  """
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [
      :id,
      :timestamp,
      :level,
      :service,
      :component,
      :message,
      :metadata,
      :workflow_id,
      :execution_id,
      :cluster
    ])
    |> validate_required([:timestamp, :level, :message])
    |> validate_inclusion(:level, ~w(debug info warning error))
  end
end
