defmodule Acs.MCP.Audience do
  @moduledoc """
  Resolves whether an MCP client is a **coding agent** or a **chat assistant**.

  Vendors (Claude vs GPT) do not matter — both chat clients share the `:chat`
  audience. Cursor / Claude Code / OpenCode share `:coding`.

  ## Resolution order

    1. Explicit tool arg (`audience` or `mode`)
    2. **URL** — path (`/mcp/chat/sse`, `/mcp/coding/sse`) or `?audience=chat|coding`
       (seeded on the SSE session before `initialize`)
    3. Session audience from MCP `initialize` `clientInfo`
    4. Application env `:mcp_default_audience` (optional)
    5. Fallback `:coding`

  Prefer URL for Claude.ai / ChatGPT connectors so tool lists match
  `priv/prompts/chat_system_prompt_body.md` (Always Active / Opt In wrappers) regardless of ambiguous `clientInfo.name`.
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
  Resolve audience from an HTTP request path and/or query params.

  Returns `nil` when the URL does not force an audience (caller should fall
  through to clientInfo / default).
  """
  @spec from_request(String.t() | nil, map() | nil) :: t() | nil
  def from_request(path, query \\ %{})

  def from_request(path, query) when is_binary(path) do
    from_path(path) || from_query(query)
  end

  def from_request(_, query), do: from_query(query)

  @doc "Force audience from MCP SSE path (`/mcp/chat/sse`, `/mcp/coding/sse`)."
  @spec from_path(String.t() | nil) :: t() | nil
  def from_path(nil), do: nil

  def from_path(path) when is_binary(path) do
    path = path |> String.split("?", parts: 2) |> hd() |> String.trim_trailing("/")

    cond do
      String.ends_with?(path, "/mcp/chat/sse") or path == "/mcp/chat/sse" -> :chat
      String.ends_with?(path, "/mcp/coding/sse") or path == "/mcp/coding/sse" -> :coding
      true -> nil
    end
  end

  def from_path(_), do: nil

  @doc "Force audience from `?audience=` / `?mode=` query params."
  @spec from_query(map() | nil) :: t() | nil
  def from_query(nil), do: nil

  def from_query(params) when is_map(params) do
    normalize(Map.get(params, "audience") || Map.get(params, "mode"))
  end

  def from_query(_), do: nil

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
      Enum.any?(@coding_hints, &String.contains?(n, &1)) ->
        :coding

      Enum.any?(@chat_hints, &String.contains?(n, &1)) ->
        :chat

      # Bare product names used by chat connectors (Claude Desktop DCR default is "Claude")
      n in ["claude", "chatgpt", "openai", "gpt", "anthropic"] ->
        :chat

      # Claude.ai / Custom Connectors often send "Claude", "claude-mcp", "Claude-XYZ"
      # without a coding hint — treat as chat (coding hints already matched above).
      String.contains?(n, "claude") ->
        :chat

      String.contains?(n, "chatgpt") or String.starts_with?(n, "gpt") ->
        :chat

      true ->
        default_audience()
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
