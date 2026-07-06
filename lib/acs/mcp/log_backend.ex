defmodule Acs.MCP.LogBackend do
  @moduledoc """
  Logger backend that captures log messages and stores them in the LogStore.
  This enables the get_logs MCP tool to retrieve recent application logs.

  Infers system tags from module paths (e.g. `Acs.Acs.Cache`
  produces tags `["acs", "module:acs", "cache", "module:cache"]`),
  enabling tag-based filtering of logs.
  """

  @behaviour :gen_event

  require Logger

  @ignored_modules [
    Acs.MCP.LogStore,
    Acs.MCP.LogBackend,
    Acs.MCP.LogStoreServer,
    Acs.MCP.HTTPServer,
    Acs.MCP.Server,
    Acs.MCP.STDIServer,
    Acs.MCP.Protocol,
    Acs.MCP.STDIOServer
  ]

  @impl true
  def init(_) do
    {:ok, %{}}
  end

  @impl true
  def handle_call(_, state) do
    {:ok, :ok, state}
  end

  @impl true
  def handle_event({_level, gl, {Logger, _, _, _}}, state) when node(gl) != node() do
    {:ok, state}
  end

  @impl true
  def handle_event({events, _handler_state}, state) when is_tuple(events) do
    events = Tuple.to_list(events)

    Enum.each(events, fn {level, gl, data} ->
      case data do
        {Logger, message, timestamp, metadata} ->
          handle_single_log(level, gl, message, timestamp, metadata)

        _ ->
          :skip
      end
    end)

    {:ok, state}
  end

  @impl true
  def handle_event({level, _gl, {Logger, message, _timestamp, metadata}}, state) do
    handle_single_log(level, nil, message, nil, metadata)
    {:ok, state}
  end

  @impl true
  def handle_event(_, state) do
    {:ok, state}
  end

  @impl true
  def handle_info(_, state) do
    {:ok, state}
  end

  @impl true
  def code_change(_old, state, _extra) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, _state) do
    :ok
  end

  # --- Private Functions ---

  defp handle_single_log(level, _gl, message, _timestamp, metadata) do
    component = extract_component(metadata)

    unless component in @ignored_modules do
      system_tags = infer_system_tags(metadata[:module])
      user_tags = List.wrap(metadata[:tags]) |> Enum.map(&normalize_tag/1)

      log_metadata =
        %{
          workflow_id: metadata[:workflow_id],
          execution_id: metadata[:execution_id],
          node_id: metadata[:node_id],
          module: metadata[:module],
          call_type: metadata[:call_type],
          agent_name: metadata[:agent_name],
          model: metadata[:model],
          provider: metadata[:provider],
          tokens_in: metadata[:tokens_in],
          tokens_out: metadata[:tokens_out],
          latency_ms: metadata[:latency_ms],
          llm_event: metadata[:llm_event],
          status: metadata[:status],
          error_type: metadata[:error_type],
          action: metadata[:action],
          params: metadata[:params],
          system_tags: system_tags,
          tags: user_tags
        }
        |> Enum.filter(fn {_, v} -> not is_nil(v) end)
        |> Map.new()

      formatted_message = format_message(message)

      service = Application.get_env(:steward_acs, :log_service_name, "acs")

      Acs.MCP.LogStore.store_log(
        level,
        service,
        format_component(component),
        formatted_message,
        log_metadata
      )
    end
  rescue
    e ->
      Logger.warning("[LogBackend] Failed to store log: #{inspect(e)}")
      nil
  end

  defp extract_component(metadata) do
    cond do
      module = metadata[:module] ->
        module

      mfa = metadata[:mfa] ->
        elem(mfa, 0)

      true ->
        "Unknown"
    end
  end

  defp format_component(module) when is_atom(module) do
    module
    |> to_string()
    |> String.replace_prefix("Elixir.", "")
    |> String.replace(".", "::")
  end

  defp format_component(other), do: to_string(other)

  defp format_message(msg) when is_binary(msg), do: msg

  defp format_message(msg) when is_list(msg) do
    try do
      IO.iodata_to_binary(msg)
    rescue
      _ -> inspect(msg)
    end
  end

  defp format_message(msg), do: inspect(msg)

  # -- Tag inference --

  defp infer_system_tags(nil), do: []

  defp infer_system_tags(module) when is_atom(module) do
    module
    |> to_string()
    |> String.replace_prefix("Elixir.", "")
    |> String.split(".")
    |> Enum.drop(1)
    |> Enum.map(&String.downcase/1)
    |> Enum.flat_map(fn segment ->
      [segment, "module:#{segment}"]
    end)
  end

  defp infer_system_tags(_), do: []

  defp normalize_tag(tag) when is_atom(tag), do: tag |> to_string() |> String.downcase()
  defp normalize_tag(tag) when is_binary(tag), do: String.downcase(tag)
end
