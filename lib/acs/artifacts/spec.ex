defmodule Acs.Artifacts.Spec do
  use Ecto.Schema
  import Ecto.Changeset

  schema "acs_specs" do
    field :organization_id, :integer
    field :company_artifact_id, :string
    field :head_revision_id, :string
    field :public_id, :string
    field :app, :string
    field :spec_id, :string
    field :title, :string
    field :status, :string
    field :document_type, :string
    field :tags_json, :string
    field :content, :string
    field :snapshot_json, :string
  end

  def changeset(spec, attrs) do
    spec
    |> cast(attrs, [
      :organization_id,
      :company_artifact_id,
      :head_revision_id,
      :public_id,
      :app,
      :spec_id,
      :title,
      :status,
      :document_type,
      :tags_json,
      :content,
      :snapshot_json
    ])
    |> validate_required([
      :organization_id,
      :company_artifact_id,
      :head_revision_id,
      :public_id,
      :app,
      :spec_id,
      :snapshot_json
    ])
    |> unique_constraint([:organization_id, :company_artifact_id])
  end
end
