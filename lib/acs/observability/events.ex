defmodule Acs.Observability.Events do
  @moduledoc """
  Structured ops logs intended for Axiom export.

  Kept as its own module so HTTPServer/Protocol (ignored by the Axiom
  Logger backend) can still emit exportable events via this process.
  """
  require Logger

  @doc "Emit an info-level structured event."
  def info(message, metadata \\ []) when is_binary(message) and is_list(metadata) do
    Logger.info(message, sanitize(metadata))
  end

  @doc "Emit a warning-level structured event."
  def warning(message, metadata \\ []) when is_binary(message) and is_list(metadata) do
    Logger.warning(message, sanitize(metadata))
  end

  @doc "Bind request-scoped Logger metadata for subsequent logs on this process."
  def put_context(metadata) when is_list(metadata) do
    Logger.metadata(sanitize(metadata))
    :ok
  end

  defp sanitize(metadata) do
    metadata
    |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)
    |> Enum.map(fn
      {k, v} when is_atom(v) -> {k, Atom.to_string(v)}
      {k, v} -> {k, v}
    end)
  end
end
