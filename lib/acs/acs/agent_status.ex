defmodule Acs.Acs.AgentStatus do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:agent_id, :string, []}
  schema "acs_agent_status" do
    field :current_task_id, :binary_id
    field :purpose, :string
    field :application, :string
    field :component, :string
    field :cluster, :string, default: "default"
    timestamps(type: :utc_datetime)
  end

  def changeset(agent_status, attrs) do
    agent_status
    |> cast(attrs, [:agent_id, :current_task_id, :purpose, :application, :component, :cluster])
    |> validate_required([:agent_id])
    |> validate_length(:application, max: 100)
    |> validate_length(:component, max: 100)
  end
end
