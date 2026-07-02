defmodule Acs.Memory.Schema do
  @moduledoc """
  Ecto schema for the acs_memories SQLite table.

  This is the derived/index table. The canonical source is YAML files.
  This table can always be regenerated from YAML.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:id, :kind, :status, :title, :summary, :content, :scope_path, :importance]}
  @primary_key {:id, :string, []}
  schema "acs_memories" do
    field :kind, :string
    field :status, :string, default: "proposed"
    field :title, :string
    field :summary, :string
    field :content, :string
    field :scope_path, :string
    field :importance, :integer, default: 3
    field :tags_json, :string
    field :triggers_json, :string
    field :failure_modes_json, :string
    field :related_memories_json, :string
    field :verification_json, :string
    field :revalidation_json, :string
    field :created_by_json, :string
    field :created_by_agent, :string
    field :parse_error, :string
    field :file_path, :string
    field :auditor_flags, :string
    field :team, :string
    field :project, :string
    field :visibility, :string, default: "org"
    timestamps(type: :utc_datetime, inserted_at: :created_at)
  end

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:id, :kind, :status, :title, :summary, :content, :scope_path,
                    :importance, :tags_json, :triggers_json, :failure_modes_json,
                    :related_memories_json, :verification_json, :revalidation_json,
                    :created_by_json, :created_by_agent, :parse_error, :file_path,
                    :auditor_flags, :team, :project, :visibility])
    |> validate_required([:id, :kind, :title, :content, :scope_path])
    |> validate_inclusion(:kind, ~w(observation learning warning pattern bug decision invariant axiom context status work_note activity))
    |> validate_inclusion(:status, ~w(proposed approved rejected stale deprecated archived parse_error))
  end
end
