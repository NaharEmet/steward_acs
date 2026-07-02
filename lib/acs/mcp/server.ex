defmodule Acs.MCP.Server do
  @moduledoc """
  Main MCP Server supervisor and configuration for Acs.

  Manages the lifecycle of MCP transports:
  - Stdio transport for CLI integration
  - HTTP/SSE transport for web-based clients

  ## Configuration

  Set the following in your config/runtime.exs or environment:

      config :steward_acs, Acs.MCP.Server,
        enabled: true,
        transport: :stdio | :http | :both,
        http_port: 4001,
        http_host: "0.0.0.0"

  ## Usage

  To run with stdio transport (for CLI integration):

      iex -S mix run --no-start
      Acs.MCP.Server.start_stdio()

  To run with HTTP transport:

      mix run --no-start
      Acs.MCP.Server.start_http()

  """
  use Supervisor

  require Logger

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    transport = opts[:transport] || get_transport_mode()
    children = build_children(transport, opts)
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Starts the MCP server with stdio transport.
  """
  def start_stdio do
    Logger.info("Starting MCP server in stdio mode...")
    Acs.MCP.StdioServer.start_link([])
  end

  @doc """
  Starts the MCP server with HTTP transport.
  """
  def start_http(opts \\ []) do
    port = opts[:port] || get_http_port()
    host = opts[:host] || get_http_host()

    Logger.info("Starting MCP server in HTTP mode on #{host}:#{port}...")

    bandit_opts = [
      plug: Acs.MCP.HTTPServer,
      scheme: :http,
      port: port,
      ip: parse_ip(host)
    ]

    Bandit.start_link(bandit_opts)
  end

  @doc """
  Returns the configured transport mode.
  """
  def get_transport_mode do
    Keyword.get(config(), :transport, :stdio)
  end

  @doc """
  Returns true if MCP server is enabled.
  """
  def enabled? do
    Keyword.get(config(), :enabled, false)
  end

  # --- Private Functions ---

  defp config do
    Application.get_env(:steward_acs, __MODULE__, [])
  end

  defp build_children(:stdio, _opts) do
    [
      Acs.MCP.StdioServer
    ]
  end

  defp build_children(:http, opts) do
    port = opts[:http_port] || get_http_port()
    host = opts[:http_host] || get_http_host()

    [
      {Bandit, plug: Acs.MCP.HTTPServer, scheme: :http, port: port, ip: parse_ip(host)}
    ]
  end

  defp build_children(:both, opts) do
    port = opts[:http_port] || get_http_port()
    host = opts[:http_host] || get_http_host()

    [
      Acs.MCP.StdioServer,
      {Bandit, plug: Acs.MCP.HTTPServer, scheme: :http, port: port, ip: parse_ip(host)}
    ]
  end

  defp get_http_port do
    Keyword.get(config(), :http_port, 4001)
  end

  defp get_http_host do
    Keyword.get(config(), :http_host, "0.0.0.0")
  end

  defp parse_ip("0.0.0.0"), do: {0, 0, 0, 0}
  defp parse_ip("127.0.0.1"), do: {127, 0, 0, 1}
  defp parse_ip("localhost"), do: {127, 0, 0, 1}

  defp parse_ip(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> ip
      _ -> {0, 0, 0, 0}
    end
  end

  defp parse_ip(_), do: {0, 0, 0, 0}
end
