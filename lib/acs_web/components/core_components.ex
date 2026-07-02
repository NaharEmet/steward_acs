defmodule AcsWeb.CoreComponents do
  @moduledoc """
  Core UI components for the Steward dashboard.
  """
  use Phoenix.Component

  attr :flash, :map, required: true, doc: "the flash assignments"

  def flash_group(assigns) do
    ~H"""
    <div class="space-y-2 mb-4">
      <%= for {kind, msg} <- @flash do %>
        <div class={"flash-#{kind}"} role="alert">
          <%= msg %>
        </div>
      <% end %>
    </div>
    """
  end

  attr :name, :string, required: true, doc: "icon name"
  attr :class, :string, default: "w-5 h-5"

  def icon(assigns) do
    ~H"""
    <span class={@class}><%= @name %></span>
    """
  end
end
