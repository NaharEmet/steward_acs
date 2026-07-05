defmodule AcsWeb.AcsLive.MemoryLive do
  @moduledoc """
  LiveView for human governance of the Steward Memory System.

  Provides:
  - Pending approvals list with approve/reject
  - Memory detail view with full content
  - Quarantined files dashboard
  - Conflict alerts for overlapping memories
  """

  use AcsWeb, :live_view
  require Logger
  alias Acs.Memory.Conflict
  alias Acs.Memory.Indexer
  alias Acs.Memory.Search

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
        memories: [],
        pending_count: 0,
        approved_count: 0,
        rejected_count: 0,
        quarantined_count: 0,
        review_count: 0,
        selected_memory: nil,
        status_filter: nil,
        kind_filter: nil,
        search_query: "",
        conflict_alerts: %{}
      )
      |> load_data()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, url, socket) do
    view = Map.get(params, "view", "pending")
    path = url |> URI.parse() |> Map.get(:path, "/")

    status_filter =
      case view do
        "quarantined" -> "parse_error"
        "rejected" -> "rejected"
        "all" -> "all"
        _ -> nil
      end

    socket =
      assign(socket, current_path: path, status_filter: status_filter, search_query: "")
      |> load_data()

    # Handle pending memory selection (after approve/reject/stale actions)
    socket =
      if pending_id = socket.assigns[:pending_memory_selection] do
        memory = Enum.find(socket.assigns.memories, fn m -> m.id == pending_id end)
        assign(socket, selected_memory: memory, pending_memory_selection: nil)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("select-memory", %{"id" => id}, socket) do
    memory = Enum.find(socket.assigns.memories, fn m -> m.id == id end)
    {:noreply, assign(socket, selected_memory: memory)}
  end

  @impl true
  def handle_event("deselect-memory", _, socket) do
    {:noreply, assign(socket, selected_memory: nil)}
  end

  @impl true
  def handle_event("approve", %{"id" => id}, socket) do
    update_memory_status(socket, id, "approved", %{
      info: "Memory '#{id}' approved ✓",
      action: "approve"
    })
  end

  @impl true
  def handle_event("reject", %{"id" => id}, socket) do
    update_memory_status(socket, id, "rejected", %{
      info: "Memory '#{id}' rejected ✗",
      action: "reject"
    })
  end

  @impl true
  def handle_event("mark-stale", %{"id" => id}, socket) do
    update_memory_status(socket, id, "stale", %{
      info: "Memory '#{id}' marked as stale ⟳",
      action: "mark stale"
    })
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    socket = assign(socket, search_query: query) |> load_data()
    {:noreply, socket}
  end

  @impl true
  def handle_event("filter-status", %{"status" => status}, socket) do
    filter = if status == "", do: nil, else: status
    socket = assign(socket, status_filter: filter) |> load_data()
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", _, socket) do
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_event("approve-all-proposed", _, socket) do
    # Fetch all proposed memories (up to 500)
    proposed_memories = Indexer.list_memories(status: "proposed", limit: 500)

    results =
      Enum.map(proposed_memories, fn memory ->
        case Indexer.update_status(memory.id, "approved") do
          {:ok, schema} ->
            attrs = build_verification_attrs("approved")

            schema
            |> Indexer.schema_to_memory_attrs()
            |> Map.merge(attrs)
            |> Acs.Memory.new()
            |> Acs.Memory.Loader.save()

            {:ok, memory.id}

          {:error, reason} ->
            {:error, memory.id, reason}
        end
      end)

    approved = Enum.count(results, fn r -> match?({:ok, _}, r) end)
    failed = Enum.count(results, fn r -> match?({:error, _, _}, r) end)

    flash_msg =
      "Approved #{approved} memories" <> if failed > 0, do: " (#{failed} failed)", else: ""

    socket = socket |> put_flash(:info, flash_msg) |> load_data()
    {:noreply, socket}
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

  defp update_memory_status(socket, id, new_status, flash_opts) do
    case Indexer.update_status(id, new_status) do
      {:ok, schema} ->
        # Persist to YAML with verification metadata
        attrs = build_verification_attrs(new_status)

        schema
        |> Indexer.schema_to_memory_attrs()
        |> Map.merge(attrs)
        |> Acs.Memory.new()
        |> Acs.Memory.Loader.save()

        # Switch to "all" view — handle_params will load data and select the memory
        socket =
          socket
          |> assign(status_filter: "all", search_query: "", pending_memory_selection: id)
          |> put_flash(:info, flash_opts[:info])

        {:noreply, push_patch(socket, to: "/memories?view=all")}

      {:error, reason} ->
        Logger.error("[MemoryLive] Failed to #{flash_opts[:action]}: #{inspect(reason)}")

        {:noreply,
         put_flash(socket, :error, "Failed to #{flash_opts[:action]}: #{inspect(reason)}")}
    end
  end

  defp build_verification_attrs("approved") do
    %{
      "status" => "approved",
      "verification" => %{
        "status" => "approved",
        "approved_by" => "human",
        "approved_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }
  end

  defp build_verification_attrs("rejected") do
    %{
      "status" => "rejected",
      "verification" => %{
        "status" => "rejected",
        "rejected_by" => "human",
        "rejected_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }
  end

  defp build_verification_attrs(_), do: %{}

  defp load_data(socket) do
    query = socket.assigns.search_query
    status_filter = socket.assigns.status_filter

    counts = Indexer.count_by_status()
    pending_count = Map.get(counts, "proposed", 0)
    approved_count = Map.get(counts, "approved", 0)
    rejected_count = Map.get(counts, "rejected", 0)
    quarantined_count = Map.get(counts, "parse_error", 0)
    review_count = Indexer.count_memories_needing_review()

    memories_opts = [limit: 100]

    memories_opts =
      case status_filter do
        nil ->
          # Default: only proposed (pending approval)
          Keyword.put(memories_opts, :status, "proposed")

        "all" ->
          # Show only active/good memories — exclude rejected and quarantined
          # The Indexer.list_memories accepts a list of statuses
          Keyword.put(memories_opts, :status, ["approved", "proposed", "stale"])

        "review" ->
          # Special: fetch memories needing human review — handled separately below
          memories_opts

        _ ->
          Keyword.put(memories_opts, :status, status_filter)
      end

    memories =
      if status_filter == "review" do
        Indexer.list_memories_needing_review(limit: 100)
      else
        if query && query != "" do
          Search.search(query, memories_opts)
        else
          Indexer.list_memories(memories_opts)
        end
      end

    conflict_alerts = compute_conflict_alerts(memories, status_filter)

    selected_memory =
      if socket.assigns.selected_memory do
        Enum.find(memories, fn m -> m.id == socket.assigns.selected_memory.id end)
      end

    assign(socket,
      memories: memories,
      selected_memory: selected_memory,
      pending_count: pending_count,
      approved_count: approved_count,
      rejected_count: rejected_count,
      quarantined_count: quarantined_count,
      review_count: review_count,
      conflict_alerts: conflict_alerts
    )
  end

  defp compute_conflict_alerts(memories, status_filter) do
    # Conflict alerts only make sense for proposed (pending approval) memories
    if status_filter == nil || status_filter == "proposed" do
      proposed = Enum.filter(memories, fn m -> m.status == "proposed" end)

      if proposed != [] do
        all_approved = Acs.Memory.Search.list(scope_path: nil, status: "approved")

        Enum.reduce(proposed, %{}, fn memory, acc ->
          tags = parse_tags_json(memory.tags_json)

          if tags != [] do
            try do
              flags = Conflict.check_in_memory(memory, tags, all_approved)

              if flags != [] do
                Map.put(acc, memory.id, flags)
              else
                acc
              end
            rescue
              exception ->
                Logger.warning(
                  "Conflict check failed for memory #{memory.id}: #{inspect(exception)}"
                )

                acc
            end
          else
            acc
          end
        end)
      else
        %{}
      end
    else
      %{}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="memory-governance">
      <!-- Search Bar -->
      <div style="margin-bottom: 20px;">
        <form phx-change="search">
          <input
            name="query"
            type="text"
            class="search-input"
            placeholder="Search memories..."
            value={@search_query}
            style="width: 100%; padding: 10px 14px; border: 1px solid var(--border); border-radius: var(--radius); background: var(--bg); color: var(--text); font-size: 0.85rem; outline: none;"
          />
        </form>
      </div>

      <!-- Stats Bar -->
      <div style="display: flex; gap: 20px; margin-bottom: 16px; font-size: 0.75rem; color: var(--muted);">
        <span><span style="font-weight: 600; color: var(--text);"><%= @pending_count %></span> Pending</span>
        <span><span style="font-weight: 600; color: var(--text);"><%= @approved_count %></span> Approved</span>
        <span><span style="font-weight: 600; color: var(--text);"><%= @rejected_count %></span> Rejected</span>
        <span><span style="font-weight: 600; color: var(--text);"><%= @quarantined_count %></span> Quarantined</span>
        <span><span style="font-weight: 600; color: var(--accent);"><%= @review_count %></span> Needs Review</span>
      </div>

      <!-- Memory List + Detail Panel -->
      <div style="display: flex; gap: 24px; align-items: flex-start;">
        <!-- Sidebar: Memory list -->
        <div style="flex: 1; display: flex; flex-direction: column; gap: 8px;">
          <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 8px;">
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
                phx-value-status="approved"
                class={"filter-tab #{if @status_filter == "approved", do: "active"}"}
              >
                Approved
              </button>
              <button
                phx-click="filter-status"
                phx-value-status="stale"
                class={"filter-tab #{if @status_filter == "stale", do: "active"}"}
              >
                Stale
              </button>
              <button
                phx-click="filter-status"
                phx-value-status="rejected"
                class={"filter-tab #{if @status_filter == "rejected", do: "active"}"}
              >
                Rejected
              </button>
              <button
                phx-click="filter-status"
                phx-value-status="deprecated"
                class={"filter-tab #{if @status_filter == "deprecated", do: "active"}"}
              >
                Deprecated
              </button>
              <button
                phx-click="filter-status"
                phx-value-status="review"
                class={"filter-tab #{if @status_filter == "review", do: "active"}"}
              >
                Needs Review
              </button>
            </div>
            <button phx-click="refresh" class="btn btn-ghost" style="padding: 6px 14px; font-size: 0.72rem;">
              ↻ Refresh
            </button>
            <%= if @pending_count > 0 do %>
              <button
                phx-click="approve-all-proposed"
                class="btn btn-primary"
                style="padding: 6px 14px; font-size: 0.72rem;"
                title={"Approve all #{@pending_count} proposed memories"}
              >
                ✓ Approve All (<%= @pending_count %>)
              </button>
            <% end %>
          </div>

          <%= if Enum.empty?(@memories) do %>
            <div class="card" style="padding: 48px;">
              <div class="empty-state">
                <div class="empty-state-icon">◈</div>
                <p class="empty-state-title">
                  <%= case @status_filter do %>
                    <% nil -> %>No memories pending approval
                    <% "all" -> %>No memories found
                    <% "review" -> %>No memories need review
                    <% status -> %>No <%= status %> memories
                  <% end %>
                </p>
              </div>
            </div>
          <% else %>
            <%= for memory <- @memories do %>
              <div
                phx-click={if @selected_memory && @selected_memory.id == memory.id, do: "deselect-memory", else: "select-memory"}
                phx-value-id={memory.id}
                class={"tool-row #{if @selected_memory && @selected_memory.id == memory.id, do: "selected"}"}
                style="cursor: pointer;"
              >
                <div style="display: flex; align-items: center; gap: 10px;">
                  <span class={"status-dot status-#{memory.status}"}></span>
                  <span class="category-badge"><%= memory.kind %></span>
                  <span style="flex: 1; font-weight: 500; font-size: 0.88rem; color: var(--text);"><%= memory.title %></span>
                  <span style="font-size: 0.7rem; color: var(--muted); font-family: var(--font-mono);">
                    I<%= memory.importance %>
                  </span>
                  <%= if count = get_conflict_count(@conflict_alerts, memory.id) do %>
                    <span class="conflict-badge" title={"#{count} conflict(s) detected"} style="display: inline-flex; align-items: center; gap: 3px; padding: 2px 6px; border-radius: 4px; background: rgba(217, 119, 6, 0.12); color: #d97706; font-size: 0.65rem; font-weight: 600; line-height: 1;">
                      ⚠ <%= count %>
                    </span>
                  <% end %>
                  <span style="font-size: 0.7rem; color: var(--muted);">
                    <%= memory.scope_path %>
                  </span>
                </div>
                <%= if memory.summary && memory.summary != "" do %>
                  <div style="font-size: 0.78rem; color: var(--text-dim); margin-top: 4px; margin-left: 22px;">
                    <%= String.slice(memory.summary, 0, 120) %><%= if String.length(memory.summary || "") > 120, do: "..." %>
                  </div>
                <% end %>
                <%= if memory.status == "proposed" do %>
                  <div style="display: flex; gap: 6px; margin-top: 8px; margin-left: 22px;">
                    <button
                      phx-click="approve"
                      phx-value-id={memory.id}
                      phx-stopPropagation
                      class="btn btn-primary"
                      style="padding: 4px 12px; font-size: 0.68rem;"
                      title="Approve and save this memory to YAML"
                    >
                      ✓ Approve & Save
                    </button>
                    <button
                      phx-click="reject"
                      phx-value-id={memory.id}
                      phx-stopPropagation
                      class="btn btn-danger"
                      style="padding: 4px 12px; font-size: 0.68rem;"
                      title="Reject this memory"
                    >
                      ✗ Reject
                    </button>
                  </div>
                <% end %>
                <%= if memory.status == "approved" do %>
                  <div style="display: flex; gap: 6px; margin-top: 8px; margin-left: 22px;">
                    <button
                      phx-click="mark-stale"
                      phx-value-id={memory.id}
                      phx-stopPropagation
                      class="btn btn-ghost"
                      style="padding: 4px 12px; font-size: 0.68rem;"
                      title="Mark this memory as stale"
                    >
                      ⟳ Mark Stale
                    </button>
                  </div>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>

        <!-- Detail panel -->
        <%= if @selected_memory do %>
          <div class="card" style="flex: 0 0 420px; padding: 20px; position: sticky; top: 16px;">
            <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px;">
              <div style="display: flex; gap: 8px; align-items: center;">
                <span class={"status-dot status-#{@selected_memory.status}"}></span>
                <span class="category-badge"><%= @selected_memory.kind %></span>
                <span style="font-size: 0.7rem; color: var(--muted); font-family: var(--font-mono);">I<%= @selected_memory.importance %></span>
              </div>
              <div style="display: flex; gap: 6px;">
                <%= if @selected_memory.status == "proposed" do %>
                  <button phx-click="approve" phx-value-id={@selected_memory.id} class="btn btn-primary" style="padding: 6px 14px; font-size: 0.72rem;" title="Approve and save this memory to YAML">
                    ✓ Approve & Save
                  </button>
                  <button phx-click="reject" phx-value-id={@selected_memory.id} class="btn btn-danger" style="padding: 6px 14px; font-size: 0.72rem;">
                    ✗ Reject
                  </button>
                <% end %>
                <%= if @selected_memory.status == "approved" do %>
                  <button phx-click="mark-stale" phx-value-id={@selected_memory.id} class="btn btn-ghost" style="padding: 6px 14px; font-size: 0.72rem;">
                    ⟳ Mark Stale
                  </button>
                <% end %>
              </div>
            </div>

            <h3 style="font-size: 1rem; margin: 0 0 12px 0; color: var(--text);"><%= @selected_memory.title %></h3>

            <div style="margin-bottom: 12px;">
              <span style="font-family: var(--font-mono); font-size: 0.65rem; color: var(--muted);">ID: </span>
              <code style="font-size: 0.72rem;"><%= @selected_memory.id %></code>
            </div>

            <div style="margin-bottom: 12px;">
              <span style="font-family: var(--font-mono); font-size: 0.65rem; color: var(--muted);">Scope: </span>
              <code style="font-size: 0.72rem;"><%= @selected_memory.scope_path %></code>
            </div>

            <%= if @selected_memory.summary do %>
              <div style="margin-bottom: 16px; padding: 10px; background: var(--bg); border-radius: var(--radius); font-size: 0.82rem; color: var(--text-dim); line-height: 1.5;">
                <%= @selected_memory.summary %>
              </div>
            <% end %>

            <%= if @selected_memory.content do %>
              <div style="margin-bottom: 16px;">
                <div style="font-family: var(--font-mono); font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.1em; color: var(--muted); margin-bottom: 6px;">Content</div>
                <pre style="background: var(--bg); border: 1px solid var(--border); border-radius: var(--radius); padding: 12px; font-size: 0.75rem; line-height: 1.5; max-height: 300px; overflow-y: auto; color: var(--text-dim);"><%= @selected_memory.content %></pre>
              </div>
            <% end %>

            <%= if @selected_memory && Map.has_key?(@conflict_alerts, @selected_memory.id) do %>
              <div style="margin-bottom: 16px;">
                <div style="font-family: var(--font-mono); font-size: 0.6rem; text-transform: uppercase; letter-spacing: 0.1em; color: #d97706; margin-bottom: 6px;">⚠ Conflict Alerts</div>
                <%= for flag <- @conflict_alerts[@selected_memory.id] do %>
                  <div style="padding: 8px 12px; margin-bottom: 6px; background: rgba(217, 119, 6, 0.08); border: 1px solid rgba(217, 119, 6, 0.2); border-radius: var(--radius); font-size: 0.75rem; color: var(--text-dim);">
                    <div style="display: flex; gap: 8px; align-items: center; margin-bottom: 4px;">
                      <span style="font-weight: 600; text-transform: uppercase; font-size: 0.65rem;"><%= flag.type %></span>
                      <span style="font-size: 0.6rem; color: var(--muted);">·</span>
                      <span style="font-size: 0.65rem;">confidence: <%= flag.confidence %></span>
                    </div>
                    <div><%= flag.reason %></div>
                  </div>
                <% end %>
              </div>
            <% end %>

            <div style="display: flex; gap: 8px; flex-wrap: wrap;">
              <div style="font-size: 0.72rem; color: var(--muted);">
                Created: <%= format_datetime(@selected_memory.created_at) %>
              </div>
              <div style="font-size: 0.72rem; color: var(--muted);">
                Updated: <%= format_datetime(@selected_memory.updated_at) %>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp format_datetime(nil), do: "N/A"
  defp format_datetime(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %d, %H:%M")
  defp format_datetime(%NaiveDateTime{} = ndt), do: Calendar.strftime(ndt, "%b %d, %H:%M")

  defp parse_tags_json(nil), do: []

  defp parse_tags_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, tags} when is_list(tags) -> tags
      _ -> []
    end
  end

  defp parse_tags_json(_), do: []

  defp get_conflict_count(alerts, id) when is_map(alerts) do
    case Map.fetch(alerts, id) do
      {:ok, flags} when is_list(flags) and flags != [] -> length(flags)
      _ -> nil
    end
  end
end
