defmodule Acs.MCP.Tools.CoreHandlersTimeTest do
  use ExUnit.Case, async: true

  alias Acs.MCP.Tools.CoreHandlers

  test "collaborator may read time" do
    assert {:ok, _} = CoreHandlers.acs_time(%{"action" => "get", "_auth_role" => "collaborator"})
  end

  test "collaborator cannot set time offset" do
    assert {:error, message} =
             CoreHandlers.acs_time(%{
               "action" => "set",
               "seconds" => 10,
               "_auth_role" => "collaborator"
             })

    assert message =~ "admin or service"
  end

  test "service role may set time offset" do
    assert {:ok, _} =
             CoreHandlers.acs_time(%{
               "action" => "set",
               "seconds" => 0,
               "_auth_role" => "service"
             })
  end
end
