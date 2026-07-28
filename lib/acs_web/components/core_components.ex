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
        <% tone = toast_tone(kind) %>
        <div
          id={"flash-#{kind}"}
          class={"toast toast-#{tone}"}
          role="alert"
          data-toast
          data-toast-message={msg}
        >
          <span class="toast-icon" aria-hidden="true"><%= toast_icon(tone) %></span>
          <div class="toast-content">
            <span class="toast-title"><%= toast_title(tone) %></span>
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

  # :info flashes are success toasts in this app; keep :warning/:error distinct.
  defp toast_tone(kind) when kind in [:error, "error"], do: "error"
  defp toast_tone(kind) when kind in [:warning, "warning"], do: "warning"
  defp toast_tone(_kind), do: "success"

  defp toast_icon("error"), do: "!"
  defp toast_icon("warning"), do: "!"
  defp toast_icon(_tone), do: "✓"

  defp toast_title("error"), do: "Something went wrong"
  defp toast_title("warning"), do: "Heads up"
  defp toast_title(_tone), do: "Success"

  attr :name, :string, required: true, doc: "icon name"
  attr :class, :string, default: "w-5 h-5"

  def icon(assigns) do
    ~H"""
    <span class={@class}><%= @name %></span>
    """
  end
end
