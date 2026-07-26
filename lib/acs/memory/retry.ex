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
    e ->
      if busy_error?(e) and retries > 1 do
        delay = 50 * round(:math.pow(2, retries - 1))
        Process.sleep(delay)
        with_busy_retry(fun, retries - 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  @doc """
  Returns true if an exception indicates a SQLite "busy" / locked condition.
  """
  def busy_error?(%Exqlite.Error{message: msg}) when is_binary(msg), do: busy_message?(msg)

  def busy_error?(e) do
    busy_message?(Exception.message(e))
  end

  defp busy_message?(msg) when is_binary(msg) do
    down = String.downcase(msg)
    String.contains?(down, "busy") or String.contains?(down, "database is locked")
  end

  defp busy_message?(_), do: false
end
