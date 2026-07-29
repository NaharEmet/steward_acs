defmodule Acs.Memory.SearchStatusFilterTest do
  use ExUnit.Case, async: true

  alias Acs.Memory.Search
  alias Acs.MCP.Tools.MemoryHandlers

  test "resolve_status_filter defaults to approved" do
    assert Search.resolve_status_filter(nil) == "approved"
    assert Search.resolve_status_filter("") == "approved"
    assert Search.resolve_status_filter(:oops) == "approved"
  end

  test "resolve_status_filter all means no filter" do
    assert Search.resolve_status_filter("all") == nil
  end

  test "resolve_status_filter keeps explicit statuses" do
    assert Search.resolve_status_filter("stale") == "stale"
    assert Search.resolve_status_filter("proposed") == "proposed"
  end

  test "chat audience cannot approve or reject via set_memory_status" do
    assert {:error, msg} =
             MemoryHandlers.set_memory_status(%{
               "memory_id" => "any",
               "status" => "approved",
               "_auth_audience" => "chat"
             })

    assert msg =~ "stale"
  end
end
