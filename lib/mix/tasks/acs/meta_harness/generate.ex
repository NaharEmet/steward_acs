defmodule Mix.Tasks.Acs.MetaHarness.Generate do
  @moduledoc """
  Generate Meta-Harness report + plan.

  Usage:
      mix acs.meta_harness.generate

  This generates a comprehensive analysis and improvement plan
  based on ACS telemetry data.
  """
  use Mix.Task

  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:steward_acs)

    IO.puts("Generating Meta-Harness analysis...")

    result = Acs.MetaHarness.Generator.generate()
    IO.puts("\n✅ Analysis complete!")
    IO.puts("   Report: #{result.report}")
    IO.puts("   Plan: #{result.plan}")
  rescue
    e ->
      IO.puts("\n❌ Generation failed: #{inspect(e)}")
      exit(1)
  end
end