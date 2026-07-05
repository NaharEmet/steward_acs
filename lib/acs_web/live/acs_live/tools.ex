defmodule AcsWeb.AcsLive.Tools do
  @moduledoc """
  LiveView for browsing registered MCP tools.
  Shows tools grouped by app with health checks and expandable detail.
  """

  use AcsWeb, :live_view
  alias Acs.MCP.ToolRegistry
  alias Acs.MCP.Bridge
  alias Acs.MCP.ToolRequests

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
        tools: [],
        tools_by_app: %{},
        app_health: %{},
        selected_tool: nil,
        stats: %{total_tools: 0, total_apps: 0, categories: [], apps: %{}},
        pending_requests_count: ToolRequests.pending_count(),
        collapsed_apps: MapSet.new()
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
  def handle_event("select-tool", %{"name" => name}, socket) do
    tool = Enum.find(socket.assigns.tools, fn t -> t["name"] == name end)

    {:noreply, assign(socket, selected_tool: tool)}
  end

  @impl true
  def handle_event("deselect-tool", _, socket) do
    {:noreply, assign(socket, selected_tool: nil)}
  end

  @impl true
  def handle_event("refresh", _, socket) do
    socket = load_data(socket)
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle-app", %{"app" => app}, socket) do
    collapsed = socket.assigns.collapsed_apps

    collapsed =
      if MapSet.member?(collapsed, app) do
        MapSet.delete(collapsed, app)
      else
        MapSet.put(collapsed, app)
      end

    {:noreply, assign(socket, collapsed_apps: collapsed)}
  end

  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket = load_tools(socket)
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
  def handle_info({:tools_refresh, _payload}, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp load_data(socket) do
    socket
    |> load_tools()
    |> load_app_health()
    |> load_collapsed_apps()
  end

  defp load_collapsed_apps(socket) do
    app_names = Map.keys(socket.assigns.tools_by_app)
    assign(socket, collapsed_apps: MapSet.new(app_names))
  end

  defp load_tools(socket) do
    tools = ToolRegistry.list_tools()
    stats = ToolRegistry.stats()

    tools_by_app =
      tools
      |> Enum.group_by(fn t -> t["app"] || "unknown" end)

    assign(socket,
      tools: tools,
      tools_by_app: tools_by_app,
      stats: stats,
      pending_requests_count: ToolRequests.pending_count()
    )
  end

  defp load_app_health(socket) do
    tools = socket.assigns.tools

    apps =
      tools
      |> Enum.map(fn t -> {t["app"] || "unknown", t["base_url"]} end)
      |> Enum.uniq()
      |> Enum.filter(fn {_app, url} -> url != "" && url != nil end)

    health_results =
      apps
      |> Task.async_stream(
        fn {app, url} ->
          case Bridge.health_check(url) do
            {:ok, _} -> {app, :up}
            {:error, _} -> {app, :down}
          end
        end,
        timeout: 6_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce(%{}, fn
        {:ok, {app, status}}, acc -> Map.put(acc, app, status)
        _, acc -> acc
      end)

    assign(socket, app_health: health_results)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="tools-dashboard">
      <!-- Stats Bar -->
      <div class="animate-in delay-1" style="display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; margin-bottom: 28px;">
        <div class="card" style="padding: 20px;">
          <div class="stat-card-label">Total Tools</div>
          <div class="stat-card-value"><%= @stats.total_tools %></div>
        </div>
        <div class="card" style="padding: 20px;">
          <div class="stat-card-label">Apps</div>
          <div class="stat-card-value"><%= @stats.total_apps %></div>
        </div>
        <div class="card" style="padding: 20px;">
          <div class="stat-card-label">Categories</div>
          <div class="stat-card-value"><%= length(@stats.categories) %></div>
        </div>
      </div>

      <!-- Tools by App -->
      <%= if Enum.empty?(@tools) do %>
        <div class="card animate-in delay-2" style="padding: 48px;">
          <div class="empty-state">
            <div class="empty-state-icon">◈</div>
            <p class="empty-state-title">No tools registered</p>
            <p class="empty-state-desc">
              Tools will appear here when they are loaded from YAML definitions or requested by agents
            </p>
          </div>
        </div>
      <% else %>
        <div style="display: flex; flex-direction: column; gap: 24px;">
          <%= for {app_name, app_tools} <- Enum.sort_by(@tools_by_app, fn {_k, v} -> length(v) end, :desc) do %>
            <section class="animate-in">
              <div class="card" style="padding: 24px;">
                <!-- App Header (clickable toggle) -->
                <div
                  class="section-header"
                  phx-click="toggle-app"
                  phx-value-app={app_name}
                  style="cursor: pointer; user-select: none;"
                >
                  <span class={"health-dot #{health_status(@app_health[app_name])}"}></span>
                  <h3 class="section-title" style="font-size: 1.1rem;"><%= app_name %></h3>
                  <span class="section-count"><%= length(app_tools) %> tools</span>
                  <span style="flex: 1;"></span>
                  <%= if is_nil(@app_health[app_name]) do %>
                    <span style="font-family: var(--font-mono); font-size: 0.65rem; color: var(--muted);">internal</span>
                  <% end %>
                  <span style="font-size: 0.85rem; color: var(--muted); margin-left: 8px;">
                    <%= if MapSet.member?(@collapsed_apps, app_name), do: "▶", else: "▼" %>
                  </span>
                </div>

                <!-- Tool List (collapsible) -->
                <%= if not MapSet.member?(@collapsed_apps, app_name) do %>
                <div style="display: flex; flex-direction: column; gap: 8px; margin-top: 16px;">
                  <%= for tool <- app_tools do %>
                    <div
                      phx-click={if @selected_tool && @selected_tool["name"] == tool["name"], do: "deselect-tool", else: "select-tool"}
                      phx-value-name={tool["name"]}
                      class={"tool-row #{if @selected_tool && @selected_tool["name"] == tool["name"], do: "selected"}"}
                    >
                      <div style="display: flex; align-items: center; gap: 12px;">
                        <span style="font-size: 0.88rem; font-weight: 500; color: var(--text); flex: 1;"><%= tool["name"] %></span>
                        <%= if tool["category"] do %>
                          <span class="category-badge"><%= tool["category"] %></span>
                        <% end %>
                        <%= if tool["level"] do %>
                          <span class="level-badge">L<%= tool["level"] %></span>
                        <% end %>
                        <span style="color: var(--muted); font-size: 0.7rem;">
                          <%= if @selected_tool && @selected_tool["name"] == tool["name"] do %>▼<% else %>▶<% end %>
                        </span>
                      </div>

                      <%= if tool["description"] && tool["description"] != "" do %>
                        <div style="font-size: 0.78rem; color: var(--text-dim); margin-top: 4px; line-height: 1.4;">
                          <%= tool["description"] %>
                        </div>
                      <% end %>

                      <!-- Expanded Detail -->
                      <%= if @selected_tool && @selected_tool["name"] == tool["name"] do %>
                        <div class="tool-detail" style="margin-top: 16px; padding-top: 16px; border-top: 1px solid var(--border);">
                          <!-- Endpoint / Method -->
                          <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 16px; margin-bottom: 16px;">
                            <div>
                              <div style="font-family: var(--font-mono); font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.1em; color: var(--muted); margin-bottom: 4px;">Endpoint</div>
                              <code style="font-size: 0.8rem; color: var(--text-dim);">
                                <%= tool["endpoint"] || tool["handler"] || "—" %>
                              </code>
                            </div>
                            <div>
                              <div style="font-family: var(--font-mono); font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.1em; color: var(--muted); margin-bottom: 4px;">Method</div>
                              <code style="font-size: 0.8rem; color: var(--text-dim);">
                                <%= tool["method"] || "—" %>
                              </code>
                            </div>
                          </div>

                          <!-- Params Table -->
                          <%= if tool["params"] && tool["params"] != [] do %>
                            <div style="margin-bottom: 16px;">
                              <div style="font-family: var(--font-mono); font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.1em; color: var(--muted); margin-bottom: 8px;">Parameters</div>
                              <table class="requests-table">
                                <thead>
                                  <tr>
                                    <th>Name</th>
                                    <th>Type</th>
                                    <th>Required</th>
                                    <th>Description</th>
                                  </tr>
                                </thead>
                                <tbody>
                                  <%= for param <- tool["params"] do %>
                                    <tr>
                                      <td style="color: var(--text); font-weight: 500; font-family: var(--font-mono); font-size: 0.78rem;">
                                        <%= param["name"] %>
                                      </td>
                                      <td><code style="font-size: 0.75rem;"><%= param["type"] || "—" %></code></td>
                                      <td style="text-align: center;">
                                        <%= if param["required"], do: "✓", else: "—" %>
                                      </td>
                                      <td style="font-size: 0.78rem;"><%= param["description"] || "" %></td>
                                    </tr>
                                  <% end %>
                                </tbody>
                              </table>
                            </div>
                          <% end %>

                          <!-- inputSchema -->
                          <%= if tool["inputSchema"] do %>
                            <div>
                              <div style="font-family: var(--font-mono); font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.1em; color: var(--muted); margin-bottom: 8px;">Input Schema</div>
                              <pre style="background: var(--bg); border: 1px solid var(--border); border-radius: var(--radius); padding: 14px; font-size: 0.72rem; line-height: 1.5; overflow-x: auto; color: var(--text-dim); max-height: 300px;"><%= format_json(tool["inputSchema"]) %></pre>
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>
              </div>
            </section>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp health_status(:up), do: "up"
  defp health_status(:down), do: "down"
  defp health_status(_), do: "unknown"

  defp format_json(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(value)
    end
  end
end
