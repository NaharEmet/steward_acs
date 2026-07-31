defmodule Acs.Prompts do
  @moduledoc """
  Loads editable prompt and instruction files from `priv/prompts/` or the
  Obsidian vault (`<vault>/orgs/<org>/prompts/`). Vault paths take priority so humans
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

  @doc "Load chat-facing instructions for a category (`skills`, `specs`)."
  def instructions_chat(category), do: load(category, "instructions_chat")

  @doc """
  Load claim-tier instructions (complete + short). Never slice the full file.

  Falls back to `instructions/1` only if no claim file exists.
  """
  def instructions_claim(category), do: load(category, "instructions_claim")

  @doc """
  Load chat claim-tier instructions. Falls back to `instructions_chat/1`.
  """
  def instructions_chat_claim(category), do: load(category, "instructions_chat_claim")

  defp candidate_paths(category, name) do
    if safe_segment?(category) and safe_segment?(name) do
      file = "#{name}.md"
      builtin = Path.join([Application.app_dir(:steward_acs), "priv/prompts"])

      [Acs.Org.prompts_dir() | Acs.Org.legacy_prompts_dirs() ++ [builtin]]
      |> Enum.uniq()
      |> Enum.map(fn root -> {root, Path.join([root, category, file])} end)
      |> Enum.filter(fn {root, path} ->
        if root == builtin do
          File.regular?(path)
        else
          Acs.Org.safe_path?(root, path) and
            match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))
        end
      end)
      |> Enum.map(&elem(&1, 1))
    else
      []
    end
  end

  defp safe_segment?(segment),
    do: Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9_-]*\z/, segment)
end
