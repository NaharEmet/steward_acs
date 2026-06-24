defmodule Mix.Tasks.Acs.MetaHarness.Report do
  @moduledoc """
  Generates a Meta-Harness improvement report.

  ## Usage

      mix acs.meta_harness.report

      # Specific timeframe
      mix acs.meta_harness.report --timeframe 30d

      # Output to file
      mix acs.meta_harness.report --output ./meta_harness.md

  ## Options

    * `--timeframe` - Time window: `7d` or `30d` (default: `24h`)
    * `--output` - Output file path (default: stdout)
  """

  use Mix.Task

  require Logger

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:steward_acs)

    opts = parse_args(args)

    timeframe = case opts[:timeframe] do
      "30d" -> :last_30_days
      _ -> :last_24_hours
    end

    report = Acs.MetaHarness.DocumentGenerator.generate(timeframe: timeframe)

    if output = opts[:output] do
      case File.write(output, report) do
        :ok -> Mix.Shell.IO.info("Report written to: #{output}")
        {:error, reason} -> Mix.Shell.IO.error("Failed to write: #{inspect(reason)}")
      end
    else
      Mix.Shell.IO.info(report)
    end
  end

  defp parse_args(args) do
    {opts, _, _} = OptionParser.parse(args,
      strict: [timeframe: :string, output: :string],
      aliases: [t: :timeframe, o: :output]
    )
    opts
  end
end