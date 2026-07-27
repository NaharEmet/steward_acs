defmodule Acs.MCP.MemoryProvenance do
  @moduledoc """
  Tags memories with the MCP SSE/HTTP endpoint they were saved from.

  Tag format: `mcp-endpoint:/mcp/coding/sse` (or `/mcp/chat/sse`, `/mcp/v1/messages`, …).
  """

  @tag_prefix "mcp-endpoint:"

  @doc "Normalize a request path for storage and tagging."
  @spec normalize_endpoint(String.t() | nil) :: String.t() | nil
  def normalize_endpoint(nil), do: nil

  def normalize_endpoint(path) when is_binary(path) do
    path
    |> String.split("?", parts: 2)
    |> hd()
    |> String.trim_trailing("/")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  def normalize_endpoint(_), do: nil

  @doc "Build the memory tag for an MCP endpoint path."
  @spec endpoint_tag(String.t() | nil) :: String.t() | nil
  def endpoint_tag(nil), do: nil

  def endpoint_tag(path) when is_binary(path) do
    case normalize_endpoint(path) do
      nil -> nil
      normalized -> @tag_prefix <> normalized
    end
  end

  @doc "Add MCP endpoint tag to a memory map when `_auth_mcp_endpoint` is present."
  @spec enrich_memory_map(map(), map()) :: map()
  def enrich_memory_map(memory_map, args) when is_map(memory_map) and is_map(args) do
    case endpoint_from_args(args) do
      nil ->
        memory_map

      endpoint ->
        tag = endpoint_tag(endpoint)
        tags = memory_map["tags"] || []

        if tag && tag not in tags do
          Map.put(memory_map, "tags", [tag | tags])
        else
          memory_map
        end
    end
  end

  @spec endpoint_from_args(map()) :: String.t() | nil
  def endpoint_from_args(args) when is_map(args) do
    args["_auth_mcp_endpoint"] || args["_mcp_endpoint"]
  end
end
