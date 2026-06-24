defmodule Acs.Repo.Migrations.AddAuditorFlagsToAcsMemories do
  use Ecto.Migration

  def change do
    alter table(:acs_memories) do
      add :auditor_flags, :text
    end
  end
end