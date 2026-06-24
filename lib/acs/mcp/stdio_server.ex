defmodule Acs.MCP.StdioServer do
  @moduledoc """
  MCP Server implementation using stdio transport.
  Reads JSON-RPC messages from stdin and writes responses to stdout.
  """
  use GenServer

  alias Acs.MCP.Protocol

  require Logger

  @default_read_timeout 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Logger.info("MCP StdioServer starting...")
    send(self(), :read_line)
    {:ok, %{read_timeout: opts[:read_timeout] || @default_read_timeout}}
  end

  @impl true
  def handle_info(:read_line, state) do
    case IO.gets("") do
      :eof ->
        Process.send_after(self(), :read_line, 100)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("MCP StdioServer read error: #{inspect(reason)}")
        Process.send_after(self(), :read_line, 500)
        {:noreply, state}

      line ->
        line = String.trim(line)

        if line != "" do
          case Protocol.handle_message(line) do
            {:ok, nil} ->
              :ok

            {:ok, response} ->
              send_response(response)

            {:sleep, id, agent_id, timeout} ->
              spawn_sleep_handler(id, agent_id, timeout)

            {:error, reason} ->
              error_response = Protocol.error_response(nil, -32700, "Parse error", reason)
              send_response(error_response)
          end
        end

        send(self(), :read_line)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:mcp_tool_response, response}, state) do
    send_response(response)
    {:noreply, state}
  end

  defp spawn_sleep_handler(id, agent_id, timeout) do
    spawn(fn ->
      try do
        result = Acs.MCP.Tools.CoreHandlers.sleep_and_wait(agent_id, timeout)

        response =
          case result do
            {:ok, data} ->
              Protocol.success_response(id, %{
                "content" => [%{"type" => "text", "text" => Jason.encode!(data, pretty: true)}]
              })

            {:error, reason} ->
              Protocol.success_response(id, %{
                "content" => [%{"type" => "text", "text" => "Error: #{inspect(reason)}"}],
                "isError" => true
              })
          end

        send(__MODULE__, {:mcp_tool_response, response})
      rescue
        e ->
          Logger.error("[StdioServer] Sleep handler crashed: #{inspect(e)}")

          error_resp =
            Protocol.success_response(id, %{
              "content" => [%{"type" => "text", "text" => "Internal error: #{inspect(e)}"}],
              "isError" => true
            })

          send(__MODULE__, {:mcp_tool_response, error_resp})
      end
    end)
  end

  defp send_response(response) do
    json = Jason.encode!(response) <> "\n"
    IO.puts(:stdio, json)
  end
end