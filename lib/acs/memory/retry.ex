defmodule Acs.Memory.Retry do
  @moduledoc """
  Provides retry logic for SQLite write operations that may encounter
  `Database busy` errors due to concurrent access.
  """

  @doc """
  Retries a function that raises `%Exqlite.Error{message: "...busy..."}`
  with exponential backoff. Non-busy errors are re-raised immediately.

  The first retry sleeps 800ms, then 400ms, 200ms, 100ms — for a total
  of 5 attempts (1 initial + 4 retries).
  """
  def with_busy_retry(fun, retries \\ 5) when is_function(fun, 0) and retries > 0 do
    fun.()
  rescue
    e in Exqlite.Error ->
      if busy_error?(e) and retries > 1 do
        delay = 50 * round(:math.pow(2, retries - 1))
        Process.sleep(delay)
        with_busy_retry(fun, retries - 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc """
  Returns true if the Exqlite.Error message indicates a "busy" condition.
  """
  def busy_error?(%Exqlite.Error{message: msg}) when is_binary(msg),
    do: String.contains?(String.downcase(msg), "busy")

  def busy_error?(_), do: false
end
