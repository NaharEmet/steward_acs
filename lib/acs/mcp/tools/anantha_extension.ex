defmodule Acs.MCP.Tools.AnanthaExtension do
  @moduledoc """
  Behaviour for Anantha-specific extension points used by diagnostic tools.

  Implementations provide fallback-safe data from the Anantha app.
  When Anantha is not configured, `Default` implementation returns empty/fallback values.
  """

  @doc """
  Fetch memory pipeline statistics from Anantha.
  Returns a map with optional keys: pipeline_worker_status, message_status_counts,
  dlq_summary, stuck_classified_messages, pending_items_summary, memory_totals_by_org,
  recent_cycles, pipeline_states.
  Returns `%{}` on failure.
  """
  @callback fetch_memory_stats(org_id :: String.t() | nil) :: map()

  @doc """
  Fetch DLQ (dead letter queue) entries from Anantha.
  Returns a list of DLQ entry maps, or `[]` on failure.
  """
  @callback fetch_dlq_entries() :: list(map())

  @doc """
  Fetch LLM provider configuration.
  Returns `%{minimax_key: String.t() | nil, nim_key: String.t() | nil}`.
  """
  @callback fetch_llm_config() :: %{optional(atom()) => String.t() | nil}
end
