defmodule AcsWeb.AcsLive.ToolRequests do
  @moduledoc """
  LiveView for managing pending and historical agent tool requests.
  Provides approve/reject workflow for the dashboard operator.
  """

  use AcsWeb, :live_view
  alias Acs.MCP.ToolRequests
  alias Acs.MCP.ToolRegistry

  def on_mount(_params, _session, socket) do
    # Don't use get_connect_info - it fails on push_navigate reconnections
    # Let handle_params set current_path from URL instead
    {:cont, assign(socket, current_path: socket.assigns[:current_path] || "/")}
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(AcsWeb.PubSub, "acs")

    socket =
      socket
      |> assign(
        pending_requests: [],
        all_requests: [],
        pending_requests_count: ToolRequests.pending_count()
      )
      |> load_data()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, url, socket) do
    path = url |> URI.parse() |> Map.get(:path, "/")
    {:noreply, assign(socket, current_path: path)}
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    case ToolRegistry.approve_request(id, "dashboard") do
      {:ok, _} ->
        socket =
          socket
          |> put_flash(:info, "Tool request approved successfully")
          |> load_data()

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> put_flash(:error, "Failed to approve: #{format_error(reason)}")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("reject", %{"id" => id}, socket) do
    case ToolRegistry.reject_request(id, "dashboard") do
      {:ok, _} ->
        socket =
          socket
          |> put_flash(:info, "Tool request rejected")
          |> load_data()

        {:noreply, socket}

      {:error, reason} ->
        socket =
          socket
          |> put_flash(:error, "Failed to reject: #{format_error(reason)}")

        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("refresh", _, socket) do
    socket = load_data(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket = load_data(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:tool_request_created, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:tool_request_approved, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:tool_request_rejected, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info({:acs_reset, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp load_data(socket) do
    pending = ToolRequests.list_requests("pending")
    all = ToolRequests.list_requests()

    assign(socket,
      pending_requests: pending,
      all_requests: all,
      pending_requests_count: length(pending)
    )
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="tool-requests-dashboard">
      <!-- Pending Requests Section -->
      <section class="animate-in delay-1" style="margin-bottom: 32px;">
        <div class="section-header">
          <h2 class="section-title">Pending Requests</h2>
          <span class="section-count"><%= length(@pending_requests) %></span>
        </div>

        <%= if Enum.empty?(@pending_requests) do %>
          <div class="card" style="padding: 48px;">
            <div class="empty-state">
              <div class="empty-state-icon">✓</div>
              <p class="empty-state-title">No pending requests</p>
              <p class="empty-state-desc">
                Agent tool requests will appear here when agents submit them via the
                <code style="color: var(--text-dim);">request_tool</code> MCP method
              </p>
            </div>
          </div>
        <% else %>
          <div style="display: flex; flex-direction: column; gap: 16px;">
            <%= for request <- @pending_requests do %>
              <div class="request-card">
                <div style="display: flex; align-items: flex-start; gap: 12px;">
                  <div style="flex: 1; min-width: 0;">
                    <div style="display: flex; align-items: center; gap: 10px; margin-bottom: 6px;">
                      <span style="font-size: 1rem; font-weight: 600; color: var(--text);"><%= request.name %></span>
                      <span class="badge badge-pending" style="display: inline-flex; align-items: center; padding: 3px 10px; font-family: var(--font-mono); font-size: 0.6rem; font-weight: 500; letter-spacing: 0.05em; text-transform: uppercase; border-radius: 20px;"><%= request.status %></span>
                      <%= if request.category do %>
                        <span class="category-badge"><%= request.category %></span>
                      <% end %>
                    </div>

                    <%= if request.description && request.description != "" do %>
                      <p style="font-size: 0.82rem; color: var(--text-dim); line-height: 1.5; margin-bottom: 8px;">
                        <%= request.description %>
                      </p>
                    <% end %>

                    <div style="display: flex; align-items: center; gap: 16px; font-size: 0.72rem; color: var(--muted);">
                      <span>
                        <span style="color: var(--text-dim);">Agent:</span>
                        <code style="font-size: 0.7rem; color: var(--text);"><%= request.agent_id %></code>
                      </span>
                      <span>·</span>
                      <span>
                        <span style="color: var(--text-dim);">Submitted:</span>
                        <span class="timestamp"><%= format_datetime(request.inserted_at) %></span>
                      </span>
                    </div>
                  </div>
                </div>

                <div class="request-actions">
                  <button
                    phx-click="approve"
                    phx-value-id={request.id}
                    class="btn btn-primary"
                    style="padding: 8px 18px; font-size: 0.72rem;"
                  >
                    ✓ Approve
                  </button>
                  <button
                    phx-click="reject"
                    phx-value-id={request.id}
                    class="btn btn-danger"
                    style="padding: 8px 18px; font-size: 0.72rem;"
                  >
                    ✕ Reject
                  </button>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </section>

      <!-- Request History Section -->
      <section class="animate-in delay-2">
        <div class="section-header">
          <h2 class="section-title">Request History</h2>
          <span class="section-count"><%= length(@all_requests) %></span>
        </div>

        <%= if Enum.empty?(@all_requests) do %>
          <div class="card" style="padding: 48px;">
            <div class="empty-state">
              <div class="empty-state-icon">○</div>
              <p class="empty-state-title">No request history</p>
              <p class="empty-state-desc">Approved and rejected requests will appear here</p>
            </div>
          </div>
        <% else %>
          <div class="card" style="padding: 0; overflow: hidden;">
            <div style="overflow-x: auto;">
              <table class="requests-table">
                <thead>
                  <tr>
                    <th>Name</th>
                    <th>Status</th>
                    <th>Category</th>
                    <th>Agent</th>
                    <th>Approved By</th>
                    <th>Date</th>
                  </tr>
                </thead>
                <tbody>
                  <%= for request <- @all_requests do %>
                    <tr>
                      <td style="color: var(--text); font-weight: 500;">
                        <%= request.name %>
                      </td>
                      <td>
                        <span class={"badge badge-#{request.status}"} style="display: inline-flex; align-items: center; padding: 3px 10px; font-family: var(--font-mono); font-size: 0.6rem; font-weight: 500; letter-spacing: 0.05em; text-transform: uppercase; border-radius: 20px;">
                          <%= request.status %>
                        </span>
                      </td>
                      <td>
                        <%= if request.category do %>
                          <span class="category-badge"><%= request.category %></span>
                        <% else %>
                          <span style="color: var(--muted);">—</span>
                        <% end %>
                      </td>
                      <td>
                        <code style="font-size: 0.75rem; color: var(--text-dim);"><%= request.agent_id %></code>
                      </td>
                      <td>
                        <%= if request.approved_by do %>
                          <code style="font-size: 0.75rem; color: var(--text-dim);"><%= request.approved_by %></code>
                        <% else %>
                          <span style="color: var(--muted);">—</span>
                        <% end %>
                      </td>
                      <td>
                        <span class="timestamp"><%= format_datetime(request.inserted_at) %></span>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
      </section>
    </div>
    """
  end

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%b %d, %H:%M")
  end

  defp format_datetime(%NaiveDateTime{} = ndt) do
    Calendar.strftime(ndt, "%b %d, %H:%M")
  end
end
