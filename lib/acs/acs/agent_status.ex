defmodule Acs.Acs.AgentStatus do
  use Ecto.Schema
  import Ecto.Changeset

  alias Acs.Repo

  @primary_key false
  schema "acs_agent_status" do
    field :agent_id, :string, primary_key: true
    field :org, :string, primary_key: true, default: "default"
    field :current_task_id, :binary_id
    field :purpose, :string
    field :application, :string
    field :component, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(agent_status, attrs) do
    agent_status
    |> cast(attrs, [:agent_id, :current_task_id, :purpose, :application, :component, :org])
    |> validate_required([:agent_id, :org])
    |> validate_length(:application, max: 100)
    |> validate_length(:component, max: 100)
  end

  @doc """
  Fetches agent status scoped to an org (composite primary key).
  """
  def get(agent_id, org \\ Acs.Org.current()) when is_binary(agent_id) and is_binary(org) do
    Repo.get_by(__MODULE__, agent_id: agent_id, org: org)
  end
end
