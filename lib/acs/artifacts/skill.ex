defmodule Acs.Artifacts.Skill do
  use Ecto.Schema
  import Ecto.Changeset

  schema "acs_skills" do
    field :organization_id, :integer
    field :company_artifact_id, :string
    field :head_revision_id, :string
    field :public_id, :string
    field :name, :string
    field :description, :string
    field :status, :string
    field :tags_json, :string
    field :scope_paths_json, :string
    field :content, :string
    field :snapshot_json, :string
  end

  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [
      :organization_id,
      :company_artifact_id,
      :head_revision_id,
      :public_id,
      :name,
      :description,
      :status,
      :tags_json,
      :scope_paths_json,
      :content,
      :snapshot_json
    ])
    |> validate_required([
      :organization_id,
      :company_artifact_id,
      :head_revision_id,
      :public_id,
      :name,
      :snapshot_json
    ])
    |> unique_constraint([:organization_id, :company_artifact_id])
  end
end
