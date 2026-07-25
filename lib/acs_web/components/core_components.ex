defmodule AcsWeb.CoreComponents do
  @moduledoc """
  Core UI components for the Steward dashboard.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  attr :flash, :map, required: true, doc: "the flash assignments"

  def flash_group(assigns) do
    ~H"""
    <div id="flash-group" class="toast-container" aria-live="assertive" aria-atomic="true">
      <%= for {kind, msg} <- @flash do %>
        <div
          id={"flash-#{kind}"}
          class={"toast toast-#{kind}"}
          role="alert"
          data-toast
          data-toast-message={msg}
        >
          <span class="toast-icon" aria-hidden="true"><%= toast_icon(kind) %></span>
          <div class="toast-content">
            <span class="toast-title"><%= toast_title(kind) %></span>
            <span class="toast-message"><%= msg %></span>
          </div>
          <button
            type="button"
            class="toast-close"
            aria-label="Close notification"
            data-toast-close
            phx-click={JS.push("lv:clear-flash", value: %{key: kind})}
          >
            <span aria-hidden="true">×</span>
          </button>
          <span class="toast-timer" aria-hidden="true"></span>
        </div>
      <% end %>
    </div>
    """
  end

  defp toast_icon(:error), do: "!"
  defp toast_icon("error"), do: "!"
  defp toast_icon(_kind), do: "✓"

  defp toast_title(:error), do: "Something went wrong"
  defp toast_title("error"), do: "Something went wrong"
  defp toast_title(_kind), do: "Success"

  attr :name, :string, required: true, doc: "icon name"
  attr :class, :string, default: "w-5 h-5"

  def icon(assigns) do
    ~H"""
    <span class={@class}><%= @name %></span>
    """
  end
end
