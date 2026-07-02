defmodule Acs.MCP.Tools.AppExtension do
  @moduledoc """
  Behaviour for app-specific extension points used by diagnostic tools.

  Implementations provide fallback-safe data from external apps (e.g., Anantha).
  When no app extension is configured, `Default` implementation returns empty/fallback values.

  Configure the active extension module via `:app_extension` in application config:
      config :steward_acs, :app_extension, MyApp.Extension
  """

  @doc """
  Fetch memory pipeline statistics from the app.
  Returns a map with optional keys: pipeline_worker_status, message_status_counts,
  dlq_summary, stuck_classified_messages, pending_items_summary, memory_totals_by_org,
  recent_cycles, pipeline_states.
  Returns `%{}` on failure.
  """
  @callback fetch_memory_stats(org_id :: String.t() | nil) :: map()

  @doc """
  Fetch DLQ (dead letter queue) entries from the app.
  Returns a list of DLQ entry maps, or `[]` on failure.
  """
  @callback fetch_dlq_entries() :: list(map())

  @doc """
  Fetch LLM provider configuration.
  Returns `%{minimax_key: String.t() | nil, nim_key: String.t() | nil}`.
  """
  @callback fetch_llm_config() :: %{optional(atom()) => String.t() | nil}
end
