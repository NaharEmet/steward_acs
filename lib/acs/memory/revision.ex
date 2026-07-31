defmodule Acs.Memory.Revision do
  @moduledoc "Immutable full snapshot of one company memory revision."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "memory_revisions" do
    field :organization_id, :integer
    field :memory_id, :string
    field :revision_number, :integer
    field :parent_revision_id, :string
    field :parent_revision_hash, :string
    field :commit_id, :string
    field :operation, :string
    field :snapshot_json, :string
    field :metadata_json, :string
    field :content_hash, :string
    field :revision_hash, :string
    field :inserted_at, :utc_datetime
  end

  def changeset(revision, attrs) do
    revision
    |> cast(attrs, [
      :id,
      :organization_id,
      :memory_id,
      :revision_number,
      :parent_revision_id,
      :parent_revision_hash,
      :commit_id,
      :operation,
      :snapshot_json,
      :metadata_json,
      :content_hash,
      :revision_hash,
      :inserted_at
    ])
    |> validate_required([
      :id,
      :organization_id,
      :memory_id,
      :revision_number,
      :commit_id,
      :operation,
      :snapshot_json,
      :metadata_json,
      :content_hash,
      :revision_hash,
      :inserted_at
    ])
    |> validate_inclusion(:operation, ~w(create revise transition restore tombstone import))
    |> unique_constraint([:organization_id, :memory_id, :revision_number],
      name: :memory_revisions_org_memory_number_index
    )
  end
end
