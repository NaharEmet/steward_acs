defmodule Acs.MCP.Audience do
  @moduledoc """
  Resolves whether an MCP client is a **coding agent** or a **chat assistant**.

  Vendors (Claude vs GPT) do not matter — both chat clients share the `:chat`
  audience. Cursor / Claude Code / OpenCode share `:coding`.

  ## Resolution order

  1. Explicit tool arg (`audience` or `mode`)
  2. Session audience from MCP `initialize` `clientInfo`
  3. Application env `:mcp_default_audience` (optional)
  4. Fallback `:coding`
  """

  @type t :: :coding | :chat

  @coding_hints [
    "cursor",
    "claude-code",
    "claude code",
    "opencode",
    "open-code",
    "vscode",
    "vs code",
    "windsurf",
    "continue.dev",
    "aider",
    "codex-cli",
    "gemini-cli"
  ]

  @chat_hints [
    "claude.ai",
    "chatgpt",
    "chat gpt",
    "openai-mcp",
    "openai mcp",
    "claude-desktop",
    "claude desktop",
    "anthropic-claude",
    "gpt-desktop",
    "messenger"
  ]

  @doc "Map guidance packet mode atoms used historically."
  def to_guidance_mode(:chat), do: :knowledge
  def to_guidance_mode(:knowledge), do: :knowledge
  def to_guidance_mode(:coding), do: :mcp
  def to_guidance_mode(:mcp), do: :mcp
  def to_guidance_mode(_), do: :mcp

  @doc "Normalize any audience/mode string or atom to `:coding` | `:chat`."
  def normalize(nil), do: nil
  def normalize(:coding), do: :coding
  def normalize(:chat), do: :chat
  def normalize(:mcp), do: :coding
  def normalize(:knowledge), do: :chat

  def normalize(value) when is_binary(value) do
    case String.downcase(String.trim(value)) do
      v when v in ["coding", "mcp", "code", "agent"] -> :coding
      v when v in ["chat", "knowledge", "assistant"] -> :chat
      _ -> nil
    end
  end

  def normalize(_), do: nil

  @doc """
  Resolve audience from tool args.

  Honors explicit `audience` or `mode`, else `_auth_audience` injected by Protocol.
  """
  def from_args(args) when is_map(args) do
    explicit =
      normalize(Map.get(args, "audience")) ||
        normalize(Map.get(args, "mode")) ||
        normalize(Map.get(args, :audience)) ||
        normalize(Map.get(args, :mode))

    cond do
      explicit ->
        explicit

      auth = normalize(Map.get(args, "_auth_audience")) ->
        auth

      true ->
        default_audience()
    end
  end

  def from_args(_), do: default_audience()

  @doc "Infer audience from MCP initialize params (`clientInfo`)."
  def from_initialize_params(params) when is_map(params) do
    client_info = params["clientInfo"] || params[:clientInfo] || %{}
    name = client_info["name"] || client_info[:name]
    from_client_name(name)
  end

  def from_initialize_params(_), do: default_audience()

  @doc "Infer audience from MCP clientInfo.name."
  def from_client_name(nil), do: default_audience()
  def from_client_name(""), do: default_audience()

  def from_client_name(name) when is_binary(name) do
    n = String.downcase(name)

    cond do
      Enum.any?(@coding_hints, &String.contains?(n, &1)) -> :coding
      Enum.any?(@chat_hints, &String.contains?(n, &1)) -> :chat
      # Bare product names used by chat connectors (Claude Desktop DCR default is "Claude")
      n in ["claude", "chatgpt", "openai", "gpt", "anthropic"] -> :chat
      true -> default_audience()
    end
  end

  def from_client_name(_), do: default_audience()

  @doc "Configured default audience (`:coding` unless overridden)."
  def default_audience do
    case Application.get_env(:steward_acs, :mcp_default_audience, :coding) do
      audience when audience in [:coding, :chat] -> audience
      "chat" -> :chat
      "coding" -> :coding
      _ -> :coding
    end
  end
end
