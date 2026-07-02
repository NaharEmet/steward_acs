defmodule Acs.MCP.Tools.AppExtension.Default do
  @moduledoc """
  Default noop implementation of `Acs.MCP.Tools.AppExtension`.
  Returns empty/fallback values when no app extension is configured.
  """
  @behaviour Acs.MCP.Tools.AppExtension

  @impl true
  def fetch_memory_stats(_org_id), do: %{}

  @impl true
  def fetch_dlq_entries, do: []

  @impl true
  def fetch_llm_config, do: %{minimax_key: nil, nim_key: nil}
end
