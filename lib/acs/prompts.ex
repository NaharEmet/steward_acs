defmodule Acs.Prompts do
  @moduledoc """
  Loads editable prompt and instruction files from `priv/prompts/` or the
  Obsidian vault (`<vault>/prompts/`). Vault paths take priority so humans
  can edit prompts in Obsidian and have agents pick them up on the next read.
  """

  @doc """
  Load a prompt file by category and name (without extension).

  Returns trimmed file content, or `default` when no file is found.
  """
  def load(category, name, opts \\ []) when is_binary(category) and is_binary(name) do
    default = Keyword.get(opts, :default, "")

    category
    |> candidate_paths(name)
    |> Enum.find_value(fn path ->
      case File.read(path) do
        {:ok, content} -> String.trim(content)
        _ -> nil
      end
    end) || default
  end

  @doc "Load agent-facing instructions for a category (`skills`, `specs`)."
  def instructions(category), do: load(category, "instructions")

  defp candidate_paths(category, name) do
    file = "#{name}.txt"
    primary = Path.join([prompts_dir(), category, file])
    builtin = Path.join([Application.app_dir(:steward_acs), "priv/prompts", category, file])

    legacy =
      if category == "memory" and name == "evaluate" do
        [Path.join(Application.app_dir(:steward_acs), "priv/evaluation_prompt/evaluate.txt")]
      else
        []
      end

    Enum.uniq([primary, builtin | legacy])
  end

  defp prompts_dir do
    obsidian = Application.get_env(:steward_acs, :obsidian_vault_path)
    org = Acs.Org.current()

    cond do
      Acs.Org.multi_tenant?() and is_binary(obsidian) and obsidian != "" ->
        Path.join([obsidian, org, "prompts"])

      is_binary(obsidian) and obsidian != "" ->
        Path.join(obsidian, "prompts")

      true ->
        Path.join(Application.app_dir(:steward_acs), "priv/prompts")
    end
  end
end
