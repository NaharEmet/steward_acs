defmodule Acs.Acs.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder,
           only: [
             :id,
             :title,
             :description,
             :status,
             :created_by_agent,
             :locked_by_agent,
             :locked_at,
             :auto_release_at,
             :event_count,
             :file_paths,
             :cluster,
             :inserted_at,
             :updated_at
           ]}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "acs_tasks" do
    field(:title, :string)
    field(:description, :string)
    field(:status, :string, default: "todo")
    field(:created_by_agent, :string)
    field(:locked_by_agent, :string)
    field(:locked_at, :utc_datetime)
    field(:auto_release_at, :utc_datetime)
    field(:event_count, :integer, default: 1)
    field(:file_paths, {:array, :string}, default: [])
    field(:cluster, :string, default: "default")
    timestamps(type: :utc_datetime)
  end

  def statuses, do: ["todo", "in_progress", "in_review", "done", "blocked"]

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :title,
      :description,
      :status,
      :created_by_agent,
      :locked_by_agent,
      :locked_at,
      :auto_release_at,
      :event_count,
      :file_paths,
      :cluster
    ])
    |> validate_required([:title, :created_by_agent])
    |> validate_inclusion(:status, statuses())
  end
end
