defmodule Acs.Repo.Migrations.AddAudienceToAcsMemories do
  use Ecto.Migration

  def change do
    alter table(:acs_memories) do
      add :audience, :string
    end
  end
end
