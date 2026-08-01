defmodule Acs.MCP.Tools.AppExtension do
  @moduledoc """
  Behaviour for the memory-pipeline extension point used by the
  `memory_health_check` and `connection_diagnostic` MCP tools.

  The default implementation, `Acs.MCP.Tools.AppExtension.Default`, feeds the
  diagnostic handlers from this repo's own real data sources (memory index,
  error traces, worker liveness, LLM config). An operator can swap in a custom
  implementation by setting `config :steward_acs, :app_extension, MyModule`.
  """

  @doc """
  Returns memory-pipeline statistics for an org as a string-keyed map.
  """
  @callback fetch_memory_stats(org_id :: String.t()) :: map()

  @doc """
  Returns recent dead-letter entries as a list of string-keyed maps.
  """
  @callback fetch_dlq_entries() :: list(map())

  @doc """
  Returns which LLM providers are configured.
  """
  @callback fetch_llm_config() :: map()
end
