ExUnit.start()

# Ensure the tmp directory exists
tmp_dir = Path.expand("../../tmp", __DIR__)
File.mkdir_p!(tmp_dir)

# Ensure migrations are run for the test database
{:ok, _} = Application.ensure_all_started(:steward_acs)

# Run migrations silently
Ecto.Migrator.run(Acs.Repo, Application.app_dir(:steward_acs, "priv/repo/migrations"), :up, all: true)

# Set sandbox to manual mode so each test can manage its own transaction
Ecto.Adapters.SQL.Sandbox.mode(Acs.Repo, :manual)
