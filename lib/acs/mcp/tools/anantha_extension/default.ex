defmodule Acs.MCP.Tools.AnanthaExtension.Default do
  @moduledoc """
  Default noop implementation of `Acs.MCP.Tools.AnanthaExtension`.
  Returns empty/fallback values when Anantha is not available.
  """
  @behaviour Acs.MCP.Tools.AnanthaExtension

  @impl true
  def fetch_memory_stats(_org_id), do: %{}

  @impl true
  def fetch_dlq_entries, do: []

  @impl true
  def fetch_llm_config, do: %{minimax_key: nil, nim_key: nil}
end
