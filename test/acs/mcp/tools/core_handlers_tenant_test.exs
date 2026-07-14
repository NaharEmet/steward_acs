defmodule Acs.MCP.Tools.CoreHandlersTenantTest do
  use Acs.DataCase, async: false

  alias Acs.MCP.Tools.CoreHandlers

  test "list_tasks ignores caller supplied org and uses authenticated org" do
    Acs.Org.with_current("org-a", fn ->
      assert {:ok, _} = Acs.create_task(%{"title" => "A task"}, "a")
    end)

    Acs.Org.with_current("org-b", fn ->
      assert {:ok, _} = Acs.create_task(%{"title" => "B task"}, "b")
    end)

    assert {:ok, %{tasks: [%{title: "A task"}], count: 1}} =
             CoreHandlers.acs_list_tasks(%{
               "_auth_org_id" => "org-a",
               "org" => "org-b"
             })
  end
end
