defmodule Acs.Memory.CompanyMemory do
  @moduledoc """
  Stable identity for a DB-backed company memory.

  Business content is never stored here. `head_revision_id` is the mutable ref
  to the latest immutable `MemoryRevision`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :string, autogenerate: false}
  schema "company_memories" do
    field :organization_id, :integer
    field :public_id, :string
    field :head_revision_id, :string
    field :created_at, :utc_datetime
  end

  def changeset(memory, attrs) do
    memory
    |> cast(attrs, [:id, :organization_id, :public_id, :head_revision_id, :created_at])
    |> validate_required([:id, :organization_id, :public_id, :created_at])
    |> unique_constraint([:organization_id, :public_id])
  end
end
