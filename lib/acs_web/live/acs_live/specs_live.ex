defmodule AcsWeb.AcsLive.SpecsLive do
  @moduledoc """
  LiveView for human governance of the Cognition Spec System.

  Provides:
  - List all specs with status filters (proposed, approved, deprecated, etc.)
  - Spec detail view with full content
  - Approve/reject/delete actions
  - Stats summary
  """

  use AcsWeb, :live_view
  require Logger

  alias Acs.Specs.Entry
  alias Acs.Specs.Loader
  alias Acs.Specs.Search

  def on_mount(_params, _session, socket) do
    {:cont, assign(socket, current_path: socket.assigns[:current_path] || "/")}
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(AcsWeb.PubSub, "acs")

    socket =
      socket
      |> assign(
        specs: [],
        stats: %{},
        selected_spec: nil,
        status_filter: nil,
        search_query: ""
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
  def handle_event("select-spec", %{"path" => _app_path}, socket) do
    # Selected via app|path compound key
    {:noreply, socket}
  end

  @impl true
  def handle_event("select-spec-detail", %{"app" => app, "id" => id}, socket) do
    case Loader.load(app, id) do
      {:ok, entry} ->
        {:noreply, assign(socket, selected_spec: entry)}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("deselect-spec", _, socket) do
    {:noreply, assign(socket, selected_spec: nil)}
  end

  @impl true
  def handle_event("approve-spec", %{"app" => app, "id" => id}, socket) do
    case Loader.load(app, id) do
      {:ok, entry} ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()
        updated = %{entry | status: "approved", approved_by: "human", updated_at: now}
        updated = %{updated | spec_hash: Entry.compute_spec_hash(updated)}

        case Loader.save(updated) do
          :ok ->
            socket =
              socket
              |> put_flash(:info, "Spec '#{app}/#{id}' approved ✓")
              |> assign(selected_spec: nil)
              |> load_data()

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to approve: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to load spec: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("reject-spec", %{"app" => app, "id" => id}, socket) do
    case Loader.load(app, id) do
      {:ok, entry} ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()
        updated = %{entry | status: "under_review", updated_at: now}

        case Loader.save(updated) do
          :ok ->
            socket =
              socket
              |> put_flash(:info, "Spec '#{app}/#{id}' rejected (moved to under_review) ✗")
              |> assign(selected_spec: nil)
              |> load_data()

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to reject: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to load spec: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("deprecate-spec", %{"app" => app, "id" => id}, socket) do
    case Loader.load(app, id) do
      {:ok, entry} ->
        now = DateTime.utc_now() |> DateTime.to_iso8601()
        updated = %{entry | status: "deprecated", updated_at: now}

        case Loader.save(updated) do
          :ok ->
            socket =
              socket
              |> put_flash(:info, "Spec '#{app}/#{id}' marked deprecated ⟳")
              |> assign(selected_spec: nil)
              |> load_data()

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Failed to deprecate: #{inspect(reason)}")}
        end

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to load spec: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("filter-status", %{"status" => status}, socket) do
    filter = if status == "", do: nil, else: status
    socket = assign(socket, status_filter: filter, selected_spec: nil) |> load_data()
    count = length(socket.assigns.specs)
    socket = put_flash(socket, :info, "Filter: #{filter || "all"} — #{count} specs")
    {:noreply, socket}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    socket = assign(socket, search_query: query, selected_spec: nil) |> load_data()
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", _, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_event("approve-all-proposed", _, socket) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    case Loader.load_all() do
      {:ok, all_specs} ->
        proposed = Enum.filter(all_specs, fn s -> s.status == "proposed" end)

        results =
          Enum.map(proposed, fn entry ->
            updated = %{entry | status: "approved", approved_by: "human", updated_at: now}
            updated = %{updated | spec_hash: Entry.compute_spec_hash(updated)}

            case Loader.save(updated) do
              :ok -> {:ok, entry.id}
              {:error, reason} -> {:error, entry.id, reason}
            end
          end)

        approved = Enum.count(results, fn r -> match?({:ok, _}, r) end)
        failed = Enum.count(results, fn r -> match?({:error, _, _}, r) end)

        flash_msg =
          "Approved #{approved} specs" <> if failed > 0, do: " (#{failed} failed)", else: ""

        socket = socket |> put_flash(:info, flash_msg) |> load_data()
        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to load specs: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event(_event, _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp load_data(socket) do
    status_filter = socket.assigns.status_filter
    search_query = socket.assigns.search_query

    stats = compute_stats()

    specs =
      if search_query && search_query != "" do
        case Search.search(search_query, status: status_filter) do
          {:ok, entries} -> entries
          _ -> []
        end
      else
        case Loader.load_all(app: nil) do
          {:ok, entries} ->
            entries
            |> maybe_filter_by_status_in_view(socket.assigns.status_filter)

          _ ->
            []
        end
      end

    # Re-select the same spec if still in the list
    selected_spec =
      if socket.assigns.selected_spec do
        Enum.find(specs, fn s ->
          s.app == socket.assigns.selected_spec.app && s.id == socket.assigns.selected_spec.id
        end)
      end

    assign(socket, specs: specs, stats: stats, selected_spec: selected_spec)
  end

  defp maybe_filter_by_status_in_view(entries, nil), do: entries

  defp maybe_filter_by_status_in_view(entries, status) do
    Enum.filter(entries, fn e -> e.status == status end)
  end

  defp compute_stats do
    statuses =
      ~w(proposed under_review approved deprecated contradicted runtime_divergent historical)

    base = Map.new(statuses, fn s -> {s, 0} end)

    case Loader.load_all() do
      {:ok, entries} ->
        Enum.reduce(entries, Map.put(base, "total", length(entries)), fn entry, acc ->
          status = entry.status || "unknown"
          Map.update(acc, status, 1, &(&1 + 1))
        end)

      _ ->
        Map.put(base, "total", 0)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="specs-governance">
      <!-- Header with stats -->
      <div style="display: flex; gap: 24px; margin-bottom: 20px; flex-wrap: wrap;">
        <div class="card" style="padding: 16px 20px; min-width: 100px;">
          <div class="stat-card-label">Total</div>
          <div class="stat-card-value"><%= @stats["total"] || 0 %></div>
        </div>
        <div class="card" style="padding: 16px 20px; min-width: 100px; border-left: 3px solid var(--amber);">
          <div class="stat-card-label">Proposed</div>
          <div class="stat-card-value"><%= @stats["proposed"] || 0 %></div>
        </div>
        <div class="card" style="padding: 16px 20px; min-width: 100px; border-left: 3px solid var(--green);">
          <div class="stat-card-label">Approved</div>
          <div class="stat-card-value"><%= @stats["approved"] || 0 %></div>
        </div>
        <div class="card" style="padding: 16px 20px; min-width: 100px; border-left: 3px solid var(--muted);">
          <div class="stat-card-label">Deprecated</div>
          <div class="stat-card-value"><%= @stats["deprecated"] || 0 %></div>
        </div>
      </div>

      <!-- Search -->
      <div style="margin-bottom: 16px;">
        <form phx-change="search">
          <input
            name="query"
            type="text"
            class="search-input"
            placeholder="Search specs by title, purpose, invariants..."
            value={@search_query}
            style="width: 100%; padding: 10px 14px; border: 1px solid var(--border); border-radius: var(--radius); background: var(--bg); color: var(--text); font-size: 0.85rem; outline: none;"
          />
        </form>
      </div>

      <!-- Filters + Refresh -->
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px;">
        <div class="filter-tabs">
          <button
            phx-click="filter-status"
            phx-value-status=""
            class={"filter-tab #{if is_nil(@status_filter), do: "active"}"}
          >
            All
          </button>
          <button
            phx-click="filter-status"
            phx-value-status="proposed"
            class={"filter-tab #{if @status_filter == "proposed", do: "active"}"}
          >
            Proposed
          </button>
          <button
            phx-click="filter-status"
            phx-value-status="under_review"
            class={"filter-tab #{if @status_filter == "under_review", do: "active"}"}
          >
            Under Review
          </button>
          <button
            phx-click="filter-status"
            phx-value-status="approved"
            class={"filter-tab #{if @status_filter == "approved", do: "active"}"}
          >
            Approved
          </button>
          <button
            phx-click="filter-status"
            phx-value-status="deprecated"
            class={"filter-tab #{if @status_filter == "deprecated", do: "active"}"}
          >
            Deprecated
          </button>
        </div>
        <button phx-click="refresh" class="btn btn-ghost" style="padding: 6px 14px; font-size: 0.72rem;">
          ↻ Refresh
        </button>
        <%= if (@stats["proposed"] || 0) > 0 do %>
          <button
            phx-click="approve-all-proposed"
            class="btn btn-primary"
            style="padding: 6px 14px; font-size: 0.72rem;"
            title={"Approve all #{@stats["proposed"]} proposed specs"}
          >
            ✓ Approve All (<%= @stats["proposed"] %>)
          </button>
        <% end %>
      </div>

      <!-- Specs List + Detail Panel -->
      <div style="display: flex; gap: 24px; align-items: flex-start;">
        <!-- List -->
        <div style="flex: 1; display: flex; flex-direction: column; gap: 8px;">
          <%= if Enum.empty?(@specs) do %>
            <div class="card" style="padding: 48px;">
              <div class="empty-state">
                <div class="empty-state-icon">◈</div>
                <p class="empty-state-title">
                  <%= if @search_query != "" do %>
                    No specs match your search
                  <% else %>
                    No specs found
                  <% end %>
                </p>
                <p class="empty-state-desc">
                  Use the specs tools via agents or create specs manually.
                </p>
              </div>
            </div>
          <% else %>
            <%= for entry <- @specs do %>
              <div
                phx-click="select-spec-detail"
                phx-value-app={entry.app}
                phx-value-id={entry.id}
                class={"tool-row #{if !@selected_spec || @selected_spec.app != entry.app || @selected_spec.id != entry.id, do: "", else: "selected"}"}
                style="cursor: pointer;"
              >
                <div style="display: flex; align-items: center; gap: 10px;">
                  <span class={"status-dot status-#{entry.status || "unknown"}"}></span>
                  <span class="category-badge"><%= entry.app %></span>
                  <span style="flex: 1; font-weight: 500; font-size: 0.88rem; color: var(--text);">
                    <%= entry.title || entry.id %>
                  </span>
                  <span style="font-size: 0.7rem; color: var(--muted); font-family: var(--font-mono);">
                    v<%= entry.version || "?" %>
                  </span>
                  <span style="font-size: 0.7rem; color: var(--muted);">
                    <%= entry.id %>
                  </span>
                  <%= if entry.verification_status do %>
                    <span style="font-size: 0.65rem; padding: 2px 6px; border-radius: 4px; background: var(--bg-elevated); color: var(--muted);">
                      <%= entry.verification_status %>
                    </span>
                  <% end %>
                </div>
                <%= if is_binary(entry.purpose) do %>
                  <div style="font-size: 0.78rem; color: var(--text-dim); margin-top: 4px; margin-left: 22px;">
                    <%= String.slice(entry.purpose, 0, 150) %><%= if String.length(entry.purpose) > 150, do: "..." %>
                  </div>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>

        <!-- Detail Panel -->
        <%= if @selected_spec do %>
          <div class="card" style="flex: 0 0 480px; padding: 24px; position: sticky; top: 16px; max-height: calc(100vh - 140px); overflow-y: auto;">
            <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px;">
              <div style="display: flex; gap: 8px; align-items: center;">
                <span class={"status-dot status-#{@selected_spec.status || "unknown"}"}></span>
                <span class="category-badge"><%= @selected_spec.app %></span>
                <span style="font-size: 0.7rem; color: var(--muted); font-family: var(--font-mono);">v<%= @selected_spec.version || "?" %></span>
              </div>
              <div style="display: flex; gap: 6px;">
                <%= if @selected_spec.status in ~w(proposed under_review) do %>
                  <button
                    phx-click="approve-spec"
                    phx-value-app={@selected_spec.app}
                    phx-value-id={@selected_spec.id}
                    class="btn btn-primary"
                    style="padding: 6px 14px; font-size: 0.72rem;"
                  >
                    ✓ Approve
                  </button>
                  <button
                    phx-click="reject-spec"
                    phx-value-app={@selected_spec.app}
                    phx-value-id={@selected_spec.id}
                    class="btn btn-danger"
                    style="padding: 6px 14px; font-size: 0.72rem;"
                  >
                    ✗ Reject
                  </button>
                <% end %>
                <%= if @selected_spec.status == "approved" do %>
                  <button
                    phx-click="deprecate-spec"
                    phx-value-app={@selected_spec.app}
                    phx-value-id={@selected_spec.id}
                    class="btn btn-ghost"
                    style="padding: 6px 14px; font-size: 0.72rem;"
                  >
                    ⟳ Deprecate
                  </button>
                <% end %>
              </div>
            </div>

            <h3 style="font-size: 1rem; margin: 0 0 8px 0; color: var(--text);">
              <%= @selected_spec.title || @selected_spec.id %>
            </h3>

            <div style="margin-bottom: 12px;">
              <code style="font-size: 0.72rem; color: var(--muted);"><%= @selected_spec.app %>/<%= @selected_spec.id %></code>
            </div>

            <!-- Purpose -->
            <%= if @selected_spec.purpose do %>
              <div style="margin-bottom: 16px;">
                <div class="agent-task-label">Purpose</div>
                <div style="font-size: 0.85rem; color: var(--text-dim); line-height: 1.5; margin-top: 4px;"><%= @selected_spec.purpose %></div>
              </div>
            <% end %>

            <!-- Invariants -->
            <%= if @selected_spec.invariants && @selected_spec.invariants != [] do %>
              <div style="margin-bottom: 16px;">
                <div class="agent-task-label">Invariants</div>
                <ul style="margin-top: 6px; padding-left: 20px;">
                  <%= if is_list(@selected_spec.invariants) do %>
                    <%= for inv <- @selected_spec.invariants do %>
                      <%= if is_binary(inv) do %>
                        <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= inv %></li>
                      <% end %>
                    <% end %>
                  <% else %>
                    <%= if is_map(@selected_spec.invariants) do %>
                      <%= for {_k, v} <- @selected_spec.invariants do %>
                        <%= if is_binary(v) do %>
                          <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= v %></li>
                        <% end %>
                      <% end %>
                    <% end %>
                  <% end %>
                </ul>
              </div>
            <% end %>

            <!-- Workflows -->
            <%= if @selected_spec.workflows && @selected_spec.workflows != [] do %>
              <div style="margin-bottom: 16px;">
                <div class="agent-task-label">Workflows</div>
                <ul style="margin-top: 6px; padding-left: 20px;">
                  <%= if is_list(@selected_spec.workflows) do %>
                    <%= for wf <- @selected_spec.workflows do %>
                      <%= if is_binary(wf) do %>
                        <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= wf %></li>
                      <% end %>
                    <% end %>
                  <% else %>
                    <%= if is_map(@selected_spec.workflows) do %>
                      <%= for {k, v} <- @selected_spec.workflows do %>
                        <%= if is_binary(v) do %>
                          <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= k %>: <%= v %></li>
                        <% else %>
                          <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= inspect(k) %></li>
                        <% end %>
                      <% end %>
                    <% end %>
                  <% end %>
                </ul>
              </div>
            <% end %>

            <!-- Failure Modes -->
            <%= if @selected_spec.failure_modes && @selected_spec.failure_modes != [] do %>
              <div style="margin-bottom: 16px;">
                <div class="agent-task-label">Failure Modes</div>
                <ul style="margin-top: 6px; padding-left: 20px;">
                  <%= if is_list(@selected_spec.failure_modes) do %>
                    <%= for fm <- @selected_spec.failure_modes do %>
                      <%= if is_binary(fm) do %>
                        <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= fm %></li>
                      <% end %>
                    <% end %>
                  <% else %>
                    <%= if is_map(@selected_spec.failure_modes) do %>
                      <%= for {_k, v} <- @selected_spec.failure_modes do %>
                        <%= if is_binary(v) do %>
                          <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= v %></li>
                        <% end %>
                      <% end %>
                    <% end %>
                  <% end %>
                </ul>
              </div>
            <% end %>

            <!-- Constraints -->
            <%= if @selected_spec.constraints && @selected_spec.constraints != [] do %>
              <div style="margin-bottom: 16px;">
                <div class="agent-task-label">Constraints</div>
                <ul style="margin-top: 6px; padding-left: 20px;">
                  <%= if is_list(@selected_spec.constraints) do %>
                    <%= for c <- @selected_spec.constraints do %>
                      <%= if is_binary(c) do %>
                        <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= c %></li>
                      <% end %>
                    <% end %>
                  <% else %>
                    <%= if is_map(@selected_spec.constraints) do %>
                      <%= for {_k, v} <- @selected_spec.constraints do %>
                        <%= if is_binary(v) do %>
                          <li style="font-size: 0.8rem; color: var(--text-dim); margin-bottom: 4px;"><%= v %></li>
                        <% end %>
                      <% end %>
                    <% end %>
                  <% end %>
                </ul>
              </div>
            <% end %>

            <!-- Tags -->
            <%= if @selected_spec.tags && @selected_spec.tags != [] do %>
              <div style="margin-bottom: 16px;">
                <div class="agent-task-label">Tags</div>
                <div style="display: flex; gap: 6px; flex-wrap: wrap; margin-top: 6px;">
                  <%= if is_list(@selected_spec.tags) do %>
                    <%= for tag <- @selected_spec.tags do %>
                      <%= if is_binary(tag) do %>
                        <span style="padding: 2px 8px; background: var(--bg-elevated); border-radius: var(--radius-sm); font-size: 0.7rem; color: var(--muted);"><%= tag %></span>
                      <% end %>
                    <% end %>
                  <% else %>
                    <%= if is_map(@selected_spec.tags) do %>
                      <%= for {_k, v} <- @selected_spec.tags do %>
                        <%= if is_binary(v) do %>
                          <span style="padding: 2px 8px; background: var(--bg-elevated); border-radius: var(--radius-sm); font-size: 0.7rem; color: var(--muted);"><%= v %></span>
                        <% end %>
                      <% end %>
                    <% end %>
                  <% end %>
                </div>
              </div>
            <% end %>

            <!-- References -->
            <%= if @selected_spec.references && @selected_spec.references != [] do %>
              <div style="margin-bottom: 16px;">
                <div class="agent-task-label">References</div>
                <div style="margin-top: 6px;">
                  <%= for ref <- @selected_spec.references do %>
                    <div style="padding: 6px 10px; margin-bottom: 4px; background: var(--bg); border-radius: var(--radius-sm); font-size: 0.75rem;">
                      <span style="color: var(--text-dim);"><%= ref["type"] || "ref" %>:</span>
                      <code style="font-size: 0.72rem; color: var(--accent);"><%= ref["target"] %></code>
                      <%= if ref["description"] do %>
                        <span style="color: var(--muted);"> — <%= ref["description"] %></span>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>
            <% end %>

            <!-- Metadata -->
            <div style="border-top: 1px solid var(--border); padding-top: 12px; margin-top: 12px;">
              <div style="display: flex; gap: 16px; flex-wrap: wrap; font-size: 0.72rem; color: var(--muted);">
                <span>Version: <strong><%= @selected_spec.version || "1" %></strong></span>
                <%= if @selected_spec.parent_version && @selected_spec.parent_version > 0 do %>
                  <span>Parent: v<%= @selected_spec.parent_version %></span>
                <% end %>
                <%= if @selected_spec.proposed_by do %>
                  <span>Proposed by: <strong><%= @selected_spec.proposed_by %></strong></span>
                <% end %>
                <%= if @selected_spec.approved_by do %>
                  <span>Approved by: <strong><%= @selected_spec.approved_by %></strong></span>
                <% end %>
              </div>
              <div style="display: flex; gap: 16px; flex-wrap: wrap; font-size: 0.72rem; color: var(--muted); margin-top: 6px;">
                <span>Verification: <%= @selected_spec.verification_status || "unset" %></span>
                <%= if @selected_spec.spec_hash do %>
                  <span title={@selected_spec.spec_hash}>
                    Hash: <code style="font-size: 0.65rem;"><%= String.slice(@selected_spec.spec_hash, 0, 12) %>…</code>
                  </span>
                <% end %>
              </div>
              <div style="display: flex; gap: 16px; margin-top: 6px; font-size: 0.72rem; color: var(--muted);">
                <span>Created: <%= @selected_spec.created_at || "—" %></span>
                <span>Updated: <%= @selected_spec.updated_at || "—" %></span>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
