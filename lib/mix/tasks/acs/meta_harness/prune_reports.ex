defmodule Mix.Tasks.Acs.MetaHarness.PruneReports do
  @moduledoc """
  Prune old metaanalysis report and plan files.

  Deletes `report_*.md` and `plan_*.md` files older than the retention
  period (default: 90 days) from the metaanalysis directory.

  ## Usage

      mix acs.meta_harness.prune_reports
      mix acs.meta_harness.prune_reports --days 30
      mix acs.meta_harness.prune_reports --dry-run
      mix acs.meta_harness.prune_reports --path /custom/path
  """

  use Mix.Task

  @default_retention_days 90
  @default_path "metaanalysis"
  @patterns ["report_*.md", "plan_*.md"]

  @impl Mix.Task
  def run(args) do
    config = parse_args!(args)
    cutoff = DateTime.add(DateTime.utc_now(), -config.days, :day)
    dir = Path.join(File.cwd!(), config.path)

    unless File.dir?(dir) do
      Mix.raise("Metaanalysis directory not found: #{dir}")
    end

    files = list_eligible_files(dir, cutoff)
    {deleted, kept} = prune(files, config.dry_run)

    Mix.Shell.IO.info(
      "PruneReports: deleted #{deleted} files, kept #{kept} files" <>
        if(config.dry_run, do: " (dry run)", else: "")
    )
  end

  defp parse_args!(args) do
    {parsed, _rest, invalid} =
      OptionParser.parse!(args,
        strict: [
          days: :integer,
          "dry-run": :boolean,
          path: :string
        ]
      )

    if invalid != [] do
      Mix.raise("Invalid options: #{Enum.join(invalid, ", ")}")
    end

    %{
      days: Keyword.get(parsed, :days, @default_retention_days),
      dry_run: Keyword.get(parsed, :"dry-run", false),
      path: Keyword.get(parsed, :path, @default_path)
    }
  end

  defp list_eligible_files(dir, cutoff) do
    @patterns
    |> Enum.flat_map(&Path.wildcard(Path.join(dir, &1)))
    |> Enum.sort()
    |> Enum.split_with(&older_than?(&1, cutoff))
  end

  defp older_than?(file_path, cutoff) do
    mtime =
      file_path
      |> File.stat!()
      |> Map.fetch!(:mtime)

    DateTime.compare(DateTime.from_naive!(mtime, "Etc/UTC"), cutoff) == :lt
  end

  defp prune({to_delete, to_keep}, dry_run) do
    Enum.each(to_delete, fn path ->
      log_deletion(path, dry_run)
      unless dry_run, do: File.rm!(path)
    end)

    {length(to_delete), length(to_keep)}
  end

  defp log_deletion(path, _dry_run) do
    Mix.Shell.IO.info("Deleting #{path}")
  end
end
