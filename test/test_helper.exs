ExUnit.start()

Code.require_file("support/data_case.ex", __DIR__)
Code.require_file("support/memory_test_helpers.ex", __DIR__)

tmp_dir = Path.expand("../../tmp", __DIR__)
File.mkdir_p!(tmp_dir)
File.mkdir_p!(Path.join(tmp_dir, "test_acs_memory"))

{:ok, _} = Application.ensure_all_started(:steward_acs)

Ecto.Migrator.run(Acs.Repo, Application.app_dir(:steward_acs, "priv/repo/migrations"), :up,
  all: true
)

Ecto.Adapters.SQL.Sandbox.mode(Acs.Repo, :manual)
