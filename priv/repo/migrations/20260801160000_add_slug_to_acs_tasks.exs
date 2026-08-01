defmodule Acs.Repo.Migrations.AddSlugToAcsTasks do
  use Ecto.Migration

  @disable_ddl_transaction true

  alias Acs.Repo

  import Ecto.Query

  def up do
    alter table(:acs_tasks) do
      add :slug, :string
    end

    flush()

    backfill_slugs()

    create unique_index(:acs_tasks, [:org, :slug], name: :acs_tasks_org_slug_index)

    if Acs.Repo.__adapter__() == Ecto.Adapters.Postgres do
      alter table(:acs_tasks) do
        modify :slug, :string, null: false
      end
    end
  end

  def down do
    drop_if_exists index(:acs_tasks, [:org, :slug], name: :acs_tasks_org_slug_index)

    alter table(:acs_tasks) do
      remove :slug
    end
  end

  defp backfill_slugs do
    tasks =
      Repo.all(
        from t in "acs_tasks",
          where: is_nil(t.slug),
          order_by: [asc: t.org, asc: t.id],
          select: %{id: t.id, title: t.title, org: t.org}
      )

    tasks
    |> Enum.reduce(%{}, fn task, used ->
      slug = unique_slug(slugify(task.title), task.org, used)

      Repo.update_all(
        from(t in "acs_tasks", where: t.id == ^task.id),
        set: [slug: slug]
      )

      Map.update(used, task.org, [slug], &[slug | &1])
    end)

    :ok
  end

  defp slugify(title) when is_binary(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 60)
    |> case do
      "" -> "task"
      slug -> slug
    end
  end

  defp slugify(_), do: "task"

  defp unique_slug(base, org, used) do
    if base in Map.get(used, org, []), do: unique_slug(base, org, used, 2), else: base
  end

  defp unique_slug(base, org, used, n) do
    candidate = "#{base}-#{n}"

    if candidate in Map.get(used, org, []),
      do: unique_slug(base, org, used, n + 1),
      else: candidate
  end
end
