defmodule Mix.Tasks.Acs.Artifacts.ImportLedger do
  use Mix.Task

  @shortdoc "Imports vault artifacts into the immutable DB ledger"

  @impl Mix.Task
  def run(args) do
    {opts, remaining, invalid} = OptionParser.parse(args, strict: [root: :string])

    if remaining != [] or invalid != [] do
      Mix.raise("Usage: mix acs.artifacts.import_ledger [--root /vaults]")
    end

    Mix.Task.run("app.start")

    case Acs.Artifacts.Importer.import(opts) do
      {:ok, summary} ->
        case Acs.Artifacts.Importer.verify(summary) do
          :ok -> Mix.shell().info("Artifact import complete: #{inspect(summary)}")
          {:error, reason} -> Mix.raise("Artifact ledger verification failed: #{inspect(reason)}")
        end

      {:error, reason} ->
        Mix.raise("Artifact import failed: #{inspect(reason)}")
    end
  end
end
