defmodule Acs.Artifacts.TenantTool do
  use Ecto.Schema
  import Ecto.Changeset

  schema "acs_tenant_tools" do
    field :organization_id, :integer
    field :company_artifact_id, :string
    field :head_revision_id, :string
    field :public_id, :string
    field :app, :string
    field :name, :string
    field :description, :string
    field :category, :string
    field :definition_json, :string
    field :snapshot_json, :string
  end

  def changeset(tool, attrs) do
    tool
    |> cast(attrs, [
      :organization_id,
      :company_artifact_id,
      :head_revision_id,
      :public_id,
      :app,
      :name,
      :description,
      :category,
      :definition_json,
      :snapshot_json
    ])
    |> validate_required([
      :organization_id,
      :company_artifact_id,
      :head_revision_id,
      :public_id,
      :app,
      :name,
      :definition_json,
      :snapshot_json
    ])
    |> unique_constraint([:organization_id, :company_artifact_id])
  end
end
