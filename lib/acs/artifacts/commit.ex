defmodule Acs.Artifacts.Commit do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "artifact_commits" do
    field :organization_id, :integer
    field :sequence, :integer
    field :parent_commit_id, :string
    field :parent_commit_hash, :string
    field :actor_type, :string
    field :actor_id, :string
    field :actor_display, :string
    field :message, :string
    field :source, :string
    field :request_id, :string
    field :commit_hash, :string
    field :committed_at, :utc_datetime
  end

  def changeset(commit, attrs) do
    commit
    |> cast(attrs, [
      :id,
      :organization_id,
      :sequence,
      :parent_commit_id,
      :parent_commit_hash,
      :actor_type,
      :actor_id,
      :actor_display,
      :message,
      :source,
      :request_id,
      :commit_hash,
      :committed_at
    ])
    |> validate_required([
      :id,
      :organization_id,
      :sequence,
      :actor_type,
      :actor_id,
      :message,
      :source,
      :commit_hash,
      :committed_at
    ])
    |> validate_inclusion(:actor_type, ~w(user developer_key system importer agent))
    |> validate_inclusion(:source, ~w(mcp web auditor migration system meta_harness))
    |> unique_constraint([:organization_id, :sequence])
  end
end
