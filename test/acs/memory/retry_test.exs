defmodule Acs.Memory.RetryTest do
  use ExUnit.Case, async: true

  alias Acs.Memory.Retry

  test "with_busy_retry retries Database busy then succeeds" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    result =
      Retry.with_busy_retry(fn ->
        n = Agent.get_and_update(agent, fn x -> {x, x + 1} end)

        if n < 2 do
          raise %Exqlite.Error{message: "Database busy"}
        else
          :ok
        end
      end)

    assert result == :ok
    assert Agent.get(agent, & &1) == 3
  end

  test "busy_error? matches locked messages" do
    assert Retry.busy_error?(%Exqlite.Error{message: "Database busy"})
    assert Retry.busy_error?(%RuntimeError{message: "database is locked"})
    refute Retry.busy_error?(%RuntimeError{message: "no such table"})
  end
end
