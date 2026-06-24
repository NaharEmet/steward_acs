defmodule Acs.Acs.FileLock do
  use Ecto.Schema
  import Ecto.Changeset

  @derive {Jason.Encoder, only: [:id, :file_path, :locked_by_agent, :locked_at, :auto_release_at, :task_id, :cluster, :inserted_at, :updated_at]}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "acs_file_locks" do
    field :file_path, :string
    field :locked_by_agent, :string
    field :locked_at, :utc_datetime
    field :auto_release_at, :utc_datetime
    field :cluster, :string, default: "default"
    belongs_to :task, Acs.Acs.Task
    timestamps(type: :utc_datetime)
  end

  def changeset(file_lock, attrs) do
    file_lock
    |> cast(attrs, [:file_path, :locked_by_agent, :locked_at, :auto_release_at, :task_id, :cluster])
    |> validate_required([:file_path, :locked_by_agent])
    |> unique_constraint(:file_path, name: :acs_file_locks_file_path_index)
  end
end