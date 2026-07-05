defmodule Mix.Tasks.Acs.Specs.Scan do
  @moduledoc """
  Scan the codebase for modules missing specs.

  Usage:
      mix acs.specs.scan                          # Scan ACS app
      mix acs.specs.scan --app my_app             # Specify app name
      mix acs.specs.scan --app my_app --dir ../.. # Custom lib dir

  This scans lib/ directories for .ex files, compares against existing
  specs, and outputs a summary of undocumented modules.
  """

  use Mix.Task

  @shortdoc "Scan for modules missing specs"

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [app: :string, dir: :string])

    app_name = opts[:app] || "steward_acs"

    lib_dir =
      if opts[:dir] do
        Path.expand(opts[:dir])
      else
        Path.join(Application.app_dir(:steward_acs), "lib")
      end

    Mix.Shell.IO.info([:green, "=== Specs Scanner ==="])
    Mix.Shell.IO.info("App: #{app_name}")
    Mix.Shell.IO.info("Lib dir: #{lib_dir}")
    Mix.Shell.IO.info("")

    # Ensure Loader is started
    {:ok, _} = Application.ensure_all_started(:steward_acs)

    results = Acs.Specs.Loader.find_undocumented(lib_dir, app: app_name)

    total_modules = count_modules(lib_dir)
    documented = total_modules - length(results)

    Mix.Shell.IO.info([:cyan, "=== Results ==="])
    Mix.Shell.IO.info("Total .ex files found: #{total_modules}")
    Mix.Shell.IO.info([:green, "Documented: #{documented}"])
    Mix.Shell.IO.info([:yellow, "Undocumented: #{length(results)}"])
    Mix.Shell.IO.info("")

    if results == [] do
      Mix.Shell.IO.info([:green, "✓ All modules have specs!"])
    else
      Mix.Shell.IO.info([:yellow, "Undocumented modules:"])

      Enum.each(results, fn %{module: mod, path: mod_path, app: detected_app} ->
        app_label = detected_app || "?"
        Mix.Shell.IO.info("  #{app_label}/#{mod_path}")
        Mix.Shell.IO.info("    Module: #{mod}")
        Mix.Shell.IO.info("")
      end)
    end

    results
  end

  defp count_modules(lib_dir) do
    lib_dir
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.count()
  end
end
