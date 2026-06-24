defmodule AcsWeb.AcsLive.ErrorTracesLive do
  @moduledoc """
  LiveView for viewing and managing error traces from Acs.MCP.ErrorTrace.
  Shows error patterns detected by the LogAnalyzer and allows agents/humans
  to acknowledge, resolve, or create tasks from them.
  """

  use AcsWeb, :live_view
  alias Acs.MCP.ErrorTrace
  alias Acs.MCP.ToolRequests

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
        traces: [],
        selected_status: "all",
        total_count: 0,
        new_count: 0,
        tasked_count: 0,
        resolved_count: 0,
        pending_requests_count: ToolRequests.pending_count()
      )
      |> load_traces()

    if connected?(socket), do: Phoenix.PubSub.subscribe(AcsWeb.PubSub, "acs")
    {:ok, socket}
  end

  @impl true
  def handle_params(_params, url, socket) do
    path = url |> URI.parse() |> Map.get(:path, "/")
    {:noreply, assign(socket, current_path: path)}
  end

  @impl true
  def handle_event("refresh", _, socket) do
    {:noreply, load_traces(socket)}
  end

  @impl true
  def handle_event("filter-status", %{"status" => status}, socket) do
    socket = assign(socket, selected_status: status) |> load_traces()
    {:noreply, socket}
  end

  @impl true
  def handle_event("acknowledge", %{"id" => id}, socket) do
    case ErrorTrace.acknowledge_trace(id) do
      {:ok, _trace} ->
        broadcast_error_traces_update()
        {:noreply, load_traces(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to acknowledge trace: #{reason}")}
    end
  end

  @impl true
  def handle_event("resolve", %{"id" => id}, socket) do
    case ErrorTrace.resolve_trace(id) do
      {:ok, _trace} ->
        broadcast_error_traces_update()
        {:noreply, load_traces(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to resolve trace: #{reason}")}
    end
  end

  @impl true
  def handle_event("create-task", %{"id" => trace_id}, socket) do
    trace = ErrorTrace.get_trace(trace_id)

    unless trace do
      {:noreply, put_flash(socket, :error, "Trace not found")}
    else
      task_title = "Auto: #{trace.service}/#{trace.component} error repeated #{trace.count}x"

      task_description =
        "Error pattern: #{String.slice(trace.message_pattern, 0, 200)}\n\n" <>
          "Total occurrences: #{trace.count}\n" <>
          "Sample message: #{trace.sample_message || "N/A"}"

      case Acs.create_task(
             %{"title" => task_title, "description" => task_description, "file_paths" => []},
             "error_traces_live"
           ) do
        {:ok, task} ->
          ErrorTrace.mark_tasked(trace.id, task.id)
          broadcast_error_traces_update()
          {:noreply, load_traces(socket)}

        {:warn, task, _similar} ->
          ErrorTrace.mark_tasked(trace.id, task.id)
          broadcast_error_traces_update()
          {:noreply, load_traces(socket)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Failed to create task: #{reason}")}
      end
    end
  end

  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info({:error_traces_updated, _payload}, socket) do
    {:noreply, load_traces(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp load_traces(socket) do
    status_filter = socket.assigns.selected_status

    traces =
      if status_filter == "all" do
        ErrorTrace.list_traces([])
      else
        ErrorTrace.list_traces(status: status_filter)
      end

    all_traces = if status_filter == "all", do: traces, else: ErrorTrace.list_traces([])

    new_count = count_status(all_traces, :new)
    tasked_count = count_status(all_traces, :tasked)
    resolved_count = count_status(all_traces, :resolved)

    assign(socket,
      traces: traces,
      total_count: length(all_traces),
      new_count: new_count,
      tasked_count: tasked_count,
      resolved_count: resolved_count,
      pending_requests_count: ToolRequests.pending_count()
    )
  end

  defp count_status(traces, status) do
    Enum.count(traces, fn t -> t.status == status end)
  end

  defp broadcast_error_traces_update do
    Phoenix.PubSub.broadcast(AcsWeb.PubSub, "acs", {:error_traces_updated, %{}})
  end

  # Date formatting
  defp format_datetime(nil), do: "N/A"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %H:%M")
  defp format_datetime(%NaiveDateTime{} = ndt), do: Calendar.strftime(ndt, "%b %d, %H:%M")

  # Trace color by status
  defp trace_color(:new), do: "var(--red)"
  defp trace_color(:acknowledged), do: "var(--amber)"
  defp trace_color(:tasked), do: "var(--teal)"
  defp trace_color(:resolved), do: "var(--green)"
  defp trace_color(:failed), do: "var(--muted)"
  defp trace_color(_), do: "var(--red)"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="acs-dashboard">
      <!-- Stats row -->
      <div style="display: grid; grid-template-columns: repeat(4, 1fr); gap: 16px; margin-bottom: 28px;">
        <div class="card" style="padding: 20px;">
          <div class="stat-card-label">Total</div>
          <div class="stat-card-value"><%= @total_count %></div>
        </div>
        <div class="card" style="padding: 20px;">
          <div class="stat-card-label">New</div>
          <div class="stat-card-value" style="color: var(--red);"><%= @new_count %></div>
        </div>
        <div class="card" style="padding: 20px;">
          <div class="stat-card-label">Tasked</div>
          <div class="stat-card-value" style="color: var(--teal);"><%= @tasked_count %></div>
        </div>
        <div class="card" style="padding: 20px;">
          <div class="stat-card-label">Resolved</div>
          <div class="stat-card-value" style="color: var(--green);"><%= @resolved_count %></div>
        </div>
      </div>

      <!-- Section header -->
      <div class="section-header">
        <h2 class="section-title">Error Traces</h2>
        <span class="section-count">(<%= @total_count %>)</span>
      </div>

      <!-- Filter tabs -->
      <div class="filter-tabs" style="margin-bottom: 20px;">
        <button phx-click="filter-status" phx-value-status="all" class={"filter-tab #{if @selected_status == "all", do: "active"}"}>All</button>
        <button phx-click="filter-status" phx-value-status="new" class={"filter-tab #{if @selected_status == "new", do: "active"}"}>New</button>
        <button phx-click="filter-status" phx-value-status="acknowledged" class={"filter-tab #{if @selected_status == "acknowledged", do: "active"}"}>Acknowledged</button>
        <button phx-click="filter-status" phx-value-status="tasked" class={"filter-tab #{if @selected_status == "tasked", do: "active"}"}>Tasked</button>
        <button phx-click="filter-status" phx-value-status="resolved" class={"filter-tab #{if @selected_status == "resolved", do: "active"}"}>Resolved</button>
        <button phx-click="filter-status" phx-value-status="failed" class={"filter-tab #{if @selected_status == "failed", do: "active"}"}>Failed</button>
      </div>

      <!-- Traces list -->
      <div class="card" style="padding: 24px;">
        <%= if Enum.empty?(@traces) do %>
          <div class="empty-state" style="padding: 48px;">
            <div class="empty-state-icon">✓</div>
            <p class="empty-state-title">No error traces</p>
            <p class="empty-state-desc">Error traces will appear here when the LogAnalyzer detects error patterns</p>
          </div>
        <% else %>
          <div style="display: flex; flex-direction: column; gap: 10px;">
            <%= for trace <- @traces do %>
              <div class="task-item" style={"border-left-color: #{trace_color(trace.status)};"}>
                <div style="display: flex; justify-content: space-between; align-items: flex-start; gap: 12px;">
                  <div style="flex: 1; min-width: 0;">
                    <div style="display: flex; align-items: center; gap: 8px; margin-bottom: 6px;">
                      <span style="font-size: 0.88rem; font-weight: 500; color: var(--text);"><%= trace.service %>/<%= trace.component %></span>
                      <span class={"badge-status badge-#{trace.status}"}><%= trace.status %></span>
                      <span style="display: inline-flex; align-items: center; justify-content: center; min-width: 22px; height: 20px; padding: 0 6px; background: var(--red-glow); color: var(--red); border-radius: 10px; font-family: var(--font-mono); font-size: 0.65rem; font-weight: 600;">
                        ×<%= trace.count %>
                      </span>
                    </div>
                    <p style="font-size: 0.82rem; color: var(--text-dim); margin-bottom: 4px; line-height: 1.4; word-break: break-all; font-family: var(--font-mono);">
                      <%= String.slice(trace.message_pattern, 0, 120) %>
                    </p>
                    <div style="display: flex; align-items: center; gap: 12px; font-size: 0.72rem; color: var(--muted);">
                      <span>First: <%= format_datetime(trace.timestamp) %></span>
                      <span>·</span>
                      <span>Last: <%= format_datetime(trace.last_seen_at) %></span>
                      <%= if trace.task_id do %>
                        <span>·</span>
                        <span>Task: <%= trace.task_id %></span>
                      <% end %>
                    </div>
                  </div>
                  <!-- Action buttons -->
                  <div style="display: flex; gap: 6px; flex-shrink: 0;">
                    <%= if trace.status == :new do %>
                      <button phx-click="acknowledge" phx-value-id={trace.id} class="btn btn-ghost" style="padding: 4px 10px; font-size: 0.7rem;">Ack</button>
                      <button phx-click="create-task" phx-value-id={trace.id} class="btn btn-primary" style="padding: 4px 10px; font-size: 0.7rem;">Create Task</button>
                    <% end %>
                    <%= if trace.status in [:new, :acknowledged] do %>
                      <button phx-click="resolve" phx-value-id={trace.id} class="btn btn-ghost" style="padding: 4px 10px; font-size: 0.7rem;">Resolve</button>
                    <% end %>
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
