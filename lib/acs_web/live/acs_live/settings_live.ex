defmodule AcsWeb.AcsLive.SettingsLive do
  @moduledoc """
  Tenant LiveView for organization settings and administrative actions.
  """

  use AcsWeb, :live_view
  alias Acs

  def on_mount(_params, _session, socket) do
    {:cont, assign(socket, current_path: socket.assigns[:current_path] || "/")}
  end

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns[:current_user]
    role = Map.get(current_user || %{}, :org_role)

    socket =
      socket
      |> assign(
        is_admin: role in ["owner", "admin"]
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, url, socket) do
    path = url |> URI.parse() |> Map.get(:path, "/")
    {:noreply, assign(socket, current_path: path)}
  end

  @impl true
  def handle_event("reset-all", _, socket) do
    if socket.assigns.is_admin do
      Acs.reset_all()

      {:noreply,
       socket
       |> put_flash(:info, "All Steward task, lock, and agent data has been reset.")}
    else
      {:noreply,
       put_flash(socket, :error, "Only organization administrators can reset workspace data.")}
    end
  end

  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="settings-shell">
      <section class="account-intro animate-in" aria-labelledby="settings-title">
        <p class="account-kicker" style="font-size: 0.5rem; margin-bottom: 6px;"><span>Workspace</span> / Configuration</p>
        <h1 id="settings-title" style="font-size: 1.3rem; margin-bottom: 6px;">Settings</h1>
        <p style="font-size: 0.82rem;">Manage workspace data and organization configuration.</p>
      </section>

      <%= if @is_admin do %>
        <div class="card" style="padding: 24px;">
          <div class="section-header" style="align-items: flex-start;">
            <div>
              <h2 class="section-title">Workspace data</h2>
              <p class="text-dim" style="font-size: 0.8rem; margin-top: 5px;">Administrative recovery actions. Resetting removes every task, file lock, and agent status in this workspace.</p>
            </div>
            <button
              phx-click="reset-all"
              data-confirm="Permanently delete all tasks, file locks, and agent statuses in this workspace? This cannot be undone."
              class="btn btn-danger"
              style="margin-left: auto;"
            >
              Reset workspace data
            </button>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
