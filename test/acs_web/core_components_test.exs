defmodule AcsWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AcsWeb.CoreComponents

  test "flash_group renders stacked dismissible notifications" do
    html =
      render_component(&CoreComponents.flash_group/1,
        flash: %{info: "Changes saved", error: "Unable to save"}
      )

    assert html =~ ~s(id="flash-group")
    assert html =~ ~s(class="toast-container")
    assert html =~ ~s(class="toast toast-info")
    assert html =~ ~s(class="toast toast-error")
    assert html =~ ~s(data-toast-close)
    assert html =~ ~s(aria-label="Close notification")
    assert html =~ "Changes saved"
    assert html =~ "Unable to save"
  end
end
