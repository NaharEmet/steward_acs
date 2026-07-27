defmodule AcsWeb.AcsLive.IndexTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AcsWeb.AcsLive.Index

  test "guides an empty workspace through first-time setup" do
    html = render_dashboard()

    assert html =~ "Workspace overview"
    assert html =~ "Connect your first agent"
    assert html =~ "Configure MCP"
    assert html =~ "View tools"
    assert html =~ "dismiss-getting-started"
  end

  test "hides getting started after it has been dismissed" do
    html = render_dashboard(getting_started_dismissed: true)

    refute html =~ "Connect your first agent"
    refute html =~ "dismiss-getting-started"
  end

  test "explains a filtered empty task list and offers to clear it" do
    html = render_dashboard(selected_status: "in_progress")

    assert html =~ "No in progress tasks"
    assert html =~ "No tasks match the current status filter."
    assert html =~ "Clear filter"
  end

  defp render_dashboard(overrides \\ []) do
    assigns =
      Map.merge(
        %{
          agent_status: %{},
          tasks: [],
          locked_files: [],
          selected_status: "all",
          can_reset_data: false,
          getting_started_dismissed: false
        },
        Map.new(overrides)
      )

    render_component(&Index.render/1, assigns)
  end
end
