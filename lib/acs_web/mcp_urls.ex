defmodule AcsWeb.McpUrls do
  @moduledoc """
  Public MCP SSE connector URLs for the dashboard.

  Symmetric paths:

  - `/mcp/coding/sse` — Cursor, Claude Code, OpenCode
  - `/mcp/chat/sse` — Claude.ai, ChatGPT

  `/mcp/sse` remains a coding alias (OAuth API identifier).
  """

  @coding_path "/mcp/coding/sse"
  @chat_path "/mcp/chat/sse"
  @chat_system_prompt_file "prompts/chat_system_prompt.md"

  @type endpoint :: %{
          id: String.t(),
          copy_status_id: String.t(),
          audience: String.t(),
          title: String.t(),
          clients: String.t(),
          path: String.t(),
          url: String.t()
        }

  @doc """
  Paste into Claude.ai / ChatGPT connector custom instructions.

  Loaded from `priv/prompts/chat_system_prompt.md`.
  """
  @spec chat_system_prompt() :: String.t()
  def chat_system_prompt do
    :code.priv_dir(:steward_acs)
    |> Path.join(@chat_system_prompt_file)
    |> File.read()
    |> case do
      {:ok, content} -> String.trim(content)
      {:error, _} -> ""
    end
  end

  @doc false
  @spec endpoints(URI.t() | nil) :: [endpoint()]
  def endpoints(uri \\ nil) do
    base = base_url(uri)

    [
      %{
        id: "mcp-coding-url",
        copy_status_id: "mcp-coding-copy-status",
        audience: "coding",
        title: "Coding",
        clients: "Cursor, Claude Code, OpenCode",
        path: @coding_path,
        url: base <> @coding_path
      },
      %{
        id: "mcp-chat-url",
        copy_status_id: "mcp-chat-copy-status",
        audience: "chat",
        title: "Chat",
        clients: "Claude.ai, ChatGPT",
        path: @chat_path,
        url: base <> @chat_path
      }
    ]
  end

  defp base_url(%URI{host: host} = uri) when is_binary(host) and host != "" do
    build_base(uri.scheme || endpoint_scheme(), host, uri.port)
  end

  defp base_url(_uri) do
    case Application.get_env(:steward_acs, :mcp_public_url) do
      url when is_binary(url) and url != "" ->
        String.trim_trailing(url, "/")

      _ ->
        build_base(endpoint_scheme(), default_host(), endpoint_port())
    end
  end

  defp default_host do
    cond do
      Acs.Org.multi_tenant?() and is_binary(Acs.Org.base_domain()) ->
        "#{Acs.Org.current()}.#{Acs.Org.base_domain()}"

      true ->
        configured_host()
    end
  end

  defp configured_host do
    account_host = Application.get_env(:steward_acs, :account_host)
    endpoint_host = endpoint_url_config() |> Keyword.get(:host)

    Enum.find([account_host, endpoint_host, "localhost"], "localhost", &valid_host?/1)
  end

  defp build_base(scheme, host, port) do
    scheme = normalize_scheme(scheme)
    port = normalize_port(port, scheme)

    %URI{scheme: scheme, host: host, port: port}
    |> URI.to_string()
    |> String.trim_trailing("/")
  end

  defp endpoint_scheme do
    endpoint_url_config() |> Keyword.get(:scheme, "http") |> normalize_scheme()
  end

  defp endpoint_port do
    endpoint_url_config()
    |> Keyword.get(:port)
    |> then(&(&1 || listener_port()))
  end

  defp listener_port do
    Application.get_env(:steward_acs, AcsWeb.Endpoint, [])
    |> Keyword.get(:http, [])
    |> Keyword.get(:port, 4001)
  end

  defp endpoint_url_config do
    Application.get_env(:steward_acs, AcsWeb.Endpoint, []) |> Keyword.get(:url, [])
  end

  defp normalize_scheme(scheme) when scheme in ["https", :https], do: "https"
  defp normalize_scheme(_), do: "http"

  defp normalize_port(nil, _), do: nil
  defp normalize_port(port, "https") when port in [443, "443"], do: nil
  defp normalize_port(port, "http") when port in [80, "80"], do: nil
  defp normalize_port(port, _) when is_integer(port), do: port
  defp normalize_port(port, _) when is_binary(port), do: String.to_integer(port)

  defp valid_host?(host) when is_binary(host) do
    Regex.match?(~r/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/i, host)
  end

  defp valid_host?(_), do: false
end
