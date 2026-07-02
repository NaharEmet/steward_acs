defmodule AcsWeb.AcsLive.Index do
  @moduledoc """
  LiveView dashboard for Agent Coordination System.
  Shows tasks, locked files, and agent status.
  """

  use AcsWeb, :live_view
  alias Acs

  def on_mount(_params, _session, socket) do
    # Don't use get_connect_info - it fails on push_navigate reconnections
    # Let handle_params set current_path from URL instead
    {:cont, assign(socket, current_path: socket.assigns[:current_path] || "/")}
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        tasks: [],
        locked_files: [],
        agent_status: %{},
        selected_status: "all",
        pending_requests_count: Acs.MCP.ToolRequests.pending_count()
      )
      |> load_data()

    if connected?(socket), do: Phoenix.PubSub.subscribe(AcsWeb.PubSub, "acs")
    {:ok, socket}
  end

  @impl true
  def handle_params(_params, url, socket) do
    path = url |> URI.parse() |> Map.get(:path, "/")
    {:noreply, assign(socket, current_path: path)}
  end

  @impl true
  def handle_event("filter-status", %{"status" => status}, socket) do
    socket = assign(socket, selected_status: status) |> load_data()
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", _, socket) do
    socket = load_data(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("reset-all", _, socket) do
    Acs.reset_all()
    socket = put_flash(socket, :info, "All Steward data has been reset.")
    socket = load_data(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:task_created, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:task_claimed, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:task_done, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:task_released, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:task_status_changed, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:file_locked, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:file_unlocked, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:agent_updated, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:agent_removed, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:acs_reset, _payload}, socket) do
    socket = put_flash(socket, :info, "Steward data was reset by another session.")
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp load_data(socket) do
    status_filter = socket.assigns.selected_status

    tasks =
      if status_filter == "all" do
        Acs.list_tasks()
      else
        Acs.list_tasks(status_filter)
      end

    agent_status = Acs.get_present_status()
    locked_files = Acs.get_locked_files()

    assign(socket,
      tasks: tasks,
      locked_files: locked_files,
      agent_status: agent_status,
      pending_requests_count: Acs.MCP.ToolRequests.pending_count()
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="acs-dashboard">

      <!-- Agent Status Section -->
      <section style="margin-bottom: 28px;">
        <div class="section-header">
          <span class="status-dot working"></span>
          <h2 class="section-title">Active Agents</h2>
          <span class="section-count">(<%= map_size(@agent_status) %>)</span>
          <button
            phx-click="reset-all"
            data-confirm="This will permanently delete all Steward tasks, file locks, and agent statuses. Are you sure?"
            class="btn btn-danger"
            style="padding: 4px 12px; font-size: 0.7rem; margin-left: auto;"
          >
            Reset All
          </button>
        </div>

        <%= if Enum.empty?(@agent_status) do %>
          <div class="card" style="padding: 48px;">
            <div class="empty-state">
              <div class="empty-state-icon">◉</div>
              <p class="empty-state-title">No active agents</p>
              <p class="empty-state-desc">Agents will appear here when they connect to the Steward server</p>
            </div>
          </div>
        <% else %>
          <div class="agents-grid">
            <%= for {agent_id, status} <- @agent_status do %>
              <div class="agent-card">
                <div class="agent-header">
                  <span class={status_dot_class(status.status)}></span>
                  <span class="agent-name"><%= agent_id %></span>
                  <span class={status_badge_class(status.status)}><%= status_label(status.status) %></span>
                </div>

                <%= if status.task do %>
                  <div class="agent-task-box">
                    <div class="agent-task-label">Current Task</div>
                    <div class="agent-task-title" title={status.task.title}><%= status.task.title %></div>
                    <%= if status.task.description do %>
                      <div class="agent-task-desc"><%= status.task.description %></div>
                    <% end %>
                    <div style="margin-top: 8px; display: flex; align-items: center; gap: 8px;">
                      <span class={"badge-status badge-#{status.task.status}"}><%= status.task.status %></span>
                    </div>
                  </div>
                <% else %>
                  <div class="agent-task-box">
                    <div class="agent-task-label">Current Task</div>
                    <div style="color: var(--muted); font-size: 0.85rem; font-style: italic;">No active task</div>
                  </div>
                <% end %>

                <%= if status.application || status.component do %>
                  <div style="margin-bottom: 12px; display: flex; gap: 16px;">
                    <%= if status.application do %>
                      <div>
                        <div class="agent-task-label">Application</div>
                        <div style="font-size: 0.8rem; color: var(--text);"><%= status.application %></div>
                      </div>
                    <% end %>
                    <%= if status.component do %>
                      <div>
                        <div class="agent-task-label">Component</div>
                        <div style="font-size: 0.8rem; color: var(--text-dim);"><%= status.component %></div>
                      </div>
                    <% end %>
                  </div>
                <% end %>

                <%= if not Enum.empty?(status.locked_files) do %>
                  <div class="agent-locks">
                    <div class="agent-locks-label">Locked Files</div>
                    <div style="display: flex; flex-wrap: wrap; gap: 6px;">
                      <%= for file <- status.locked_files do %>
                        <span class="lock-file-tag" title={file}><%= Path.basename(file) %></span>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </section>

      <!-- Tasks & Locks Grid -->
      <div class="two-col-grid">

        <!-- Tasks Column -->
        <section>
          <div class="card" style="padding: 24px;">
            <div class="section-header">
              <h2 class="section-title">Tasks</h2>
              <span class="section-count">(<%= length(@tasks) %>)</span>
            </div>

            <div class="filter-tabs" style="margin-bottom: 20px;">
              <%= for status <- ["all", "todo", "claimed", "in_progress", "done"] do %>
                <button
                  phx-click="filter-status"
                  phx-value-status={status}
                  class={if @selected_status == status, do: "filter-tab active", else: "filter-tab"}
                >
                  <%= String.capitalize(status) %>
                </button>
              <% end %>
            </div>

            <div class="scroll-area">
              <%= if Enum.empty?(@tasks) do %>
                <div class="empty-state" style="padding: 32px;">
                  <div class="empty-state-icon">○</div>
                  <p class="empty-state-title">No tasks found</p>
                </div>
              <% else %>
                <div style="display: flex; flex-direction: column; gap: 10px;">
                  <%= for task <- @tasks do %>
                    <div class={if task.event_count && task.event_count > 1, do: "task-item priority", else: "task-item"}>
                      <div style="display: flex; justify-content: space-between; align-items: flex-start; gap: 12px;">
                        <div style="flex: 1; min-width: 0;">
                          <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 4px;">
                            <span style="font-size: 0.9rem; font-weight: 500; color: var(--text);" class="truncate"><%= task.title %></span>
                            <%= if task.event_count && task.event_count > 1 do %>
                              <span style="display: inline-flex; align-items: center; justify-content: center; min-width: 20px; height: 18px; padding: 0 6px; background: var(--amber-glow); color: var(--amber); border-radius: 10px; font-family: var(--font-mono); font-size: 0.65rem; font-weight: 600;">
                                ×<%= task.event_count %>
                              </span>
                            <% end %>
                          </div>
                          <%= if task.description do %>
                            <p style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 6px; line-height: 1.4;" class="line-clamp-2"><%= task.description %></p>
                          <% end %>
                          <div style="display: flex; align-items: center; gap: 8px; font-size: 0.72rem; color: var(--muted);">
                            <span style="font-family: var(--font-mono);"><%= task.created_by_agent %></span>
                            <span>·</span>
                            <span class="timestamp"><%= format_datetime(task.inserted_at) %></span>
                          </div>
                        </div>
                        <span class={"badge-status badge-#{task.status}"}><%= task.status %></span>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </section>

        <!-- Locked Files Column -->
        <section>
          <div class="card" style="padding: 24px;">
            <div class="section-header">
              <h2 class="section-title">Locked Files</h2>
              <span class="section-count">(<%= length(@locked_files) %>)</span>
            </div>

            <div class="scroll-area">
              <%= if Enum.empty?(@locked_files) do %>
                <div class="empty-state" style="padding: 32px;">
                  <div class="empty-state-icon">🔓</div>
                  <p class="empty-state-title">No files locked</p>
                  <p class="empty-state-desc">File locks will appear here when agents lock files</p>
                </div>
              <% else %>
                <div style="display: flex; flex-direction: column; gap: 10px;">
                  <%= for lock <- @locked_files do %>
                    <div class="lock-item">
                      <div style="display: flex; justify-content: space-between; align-items: flex-start; gap: 12px; margin-bottom: 8px;">
                        <code class="mono" style="font-size: 0.78rem; color: var(--text); word-break: break-all; flex: 1;"><%= lock.file_path %></code>
                        <span style="font-size: 0.72rem; color: var(--muted); shrink: 0;"><%= lock.locked_by_agent %></span>
                      </div>
                      <div style="display: flex; align-items: center; gap: 12px; font-size: 0.72rem; color: var(--muted);">
                        <span>
                          <span style="color: var(--text-dim);">Locked:</span>
                          <span class="timestamp"><%= if lock.locked_at, do: format_datetime(lock.locked_at), else: "N/A" %></span>
                        </span>
                        <span>·</span>
                        <span>
                          <span style="color: var(--text-dim);">Expires:</span>
                          <span class="timestamp"><%= if lock.auto_release_at, do: format_datetime(lock.auto_release_at), else: "N/A" %></span>
                        </span>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          </div>
        </section>

      </div>
    </div>
    """
  end

  # Status helpers
  defp status_dot_class("working"), do: "status-dot working"
  defp status_dot_class(_), do: "status-dot sleeping"

  defp status_badge_class("working"), do: "badge badge-working"
  defp status_badge_class(_), do: "badge badge-sleeping"

  defp status_label("working"), do: "Working"
  defp status_label(_), do: "Sleeping"

  # Date formatting
  defp format_datetime(nil), do: "N/A"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %H:%M")
  defp format_datetime(%NaiveDateTime{} = ndt), do: Calendar.strftime(ndt, "%b %d, %H:%M")
end
