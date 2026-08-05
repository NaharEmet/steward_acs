defmodule Acs.MetaHarness do
  @moduledoc """
  Meta-Harness feature gate and shared config.

  Single source of truth for `META_HARNESS_ENABLED` — Application, AgentOps,
  and mix tasks must all call `enabled?/0` so defaults stay aligned.
  """

  @doc """
  Whether Meta-Harness ingestion + hourly rollups are active.

  Default: `true` (matches compose / multitenant prod).
  """
  @spec enabled?() :: boolean()
  def enabled? do
    System.get_env("META_HARNESS_ENABLED", "true") == "true"
  end
end
