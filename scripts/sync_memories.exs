# scripts/sync_memories.exs
#
# Run: mix run scripts/sync_memories.exs
# This syncs all YAML memory files from priv/acs_memory/ into the SQLite index.

alias Acs.Memory.Indexer

# The app is already started by `mix run`
case Indexer.sync_all() do
  {:ok, count, quarantined} ->
    IO.puts("Synced #{count} memories, #{length(quarantined)} quarantined")

    if quarantined != [] do
      IO.puts("Quarantined files:")
      Enum.each(quarantined, fn {:quarantine, path, reason} ->
        IO.puts("  #{path}: #{reason}")
      end)
    end

  {:error, reason} ->
    IO.puts("Sync failed: #{inspect(reason)}")
end
