defmodule Mix.Tasks.Acs.Memory.BackfillLedger do
  use Mix.Task

  @shortdoc "Imports legacy memory projection rows into the immutable DB ledger"

  @moduledoc """
  Imports each `acs_memories` row without a ledger head as an immutable `import`
  revision. The operation is idempotent because imported rows receive their
  company-memory and head-revision pointers in the same transaction.

      mix acs.memory.backfill_ledger

  Run this after migrations and before enabling DB-only multi-tenant writes.
  """

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    case Acs.Memory.Ledger.backfill_projection() do
      {:ok, count} -> Mix.shell().info("Imported #{count} memories into the immutable ledger")
      {:error, reason} -> Mix.raise("Ledger backfill failed: #{inspect(reason)}")
    end
  end
end
