defmodule AcsWeb.AcsLive.SkillsLive do
  @moduledoc """
  LiveView for human governance of externally managed skill files.

  Skill content is read-only here. Reviewers can browse, search, approve, or
  reject skills by updating governance fields in their YAML frontmatter.
  """

  use AcsWeb, :live_view

  alias Acs.Skills.Store
  alias Acs.Abac

  def on_mount(_params, _session, socket) do
    {:cont, assign(socket, current_path: socket.assigns[:current_path] || "/")}
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        skills: [],
        selected_skill: nil,
        search_query: "",
        status_filter: "proposed",
        stats: empty_stats()
      )

    socket =
      if connected?(socket) do
        send(self(), :load_data)
        socket
      else
        load_data(socket)
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, url, socket) do
    path = url |> URI.parse() |> Map.get(:path, "/")
    {:noreply, assign(socket, current_path: path)}
  end

  @impl true
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply, socket |> assign(search_query: query, selected_skill: nil) |> load_data()}
  end

  def handle_event("filter-status", %{"status" => status}, socket) do
    filter = if status == "", do: nil, else: status
    {:noreply, socket |> assign(status_filter: filter, selected_skill: nil) |> load_data()}
  end

  def handle_event("select-skill", %{"id" => id}, socket) do
    skill = Enum.find(socket.assigns.skills, &(&1.id == id))
    {:noreply, assign(socket, selected_skill: skill)}
  end

  def handle_event("approve", %{"id" => id}, socket),
    do: update_status(socket, id, "approved")

  def handle_event("reject", %{"id" => id}, socket),
    do: update_status(socket, id, "rejected")

  def handle_event("refresh", _params, socket), do: {:noreply, load_data(socket)}
  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:load_data, socket), do: {:noreply, load_data(socket)}

  defp update_status(socket, id, status) do
    ctx = viewer_abac(socket)

    case Store.get_skill(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Skill '#{id}' not found")}

      skill ->
        if Abac.can_edit?(ctx, skill) do
          case Store.update_status(id, status, "human") do
            :ok ->
              verb = if status == "approved", do: "approved", else: "rejected"

              {:noreply,
               socket
               |> assign(selected_skill: nil)
               |> put_flash(:info, "Skill '#{id}' #{verb}")
               |> load_data()}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Failed to update skill: #{inspect(reason)}")}
          end
        else
          {:noreply,
           put_flash(
             socket,
             :error,
             "Access denied: cannot edit skills at or above your clearance"
           )}
        end
    end
  end

  # Same clearance rule as MCP: viewer's own authority level + role.
  defp viewer_abac(socket) do
    case socket.assigns[:current_user] do
      %{org_role: role, authority_level_slug: slug} ->
        Abac.from_keyword(
          agent_role: role,
          authority_level_slug: slug
        )

      %{org_role: role} ->
        Abac.from_keyword(agent_role: role)

      %{authority_level_slug: slug} ->
        Abac.from_keyword(authority_level_slug: slug)

      _ ->
        Abac.from_keyword([])
    end
  end

  defp load_data(socket) do
    ctx = viewer_abac(socket)

    all_skills =
      Store.all_skills()
      |> Abac.filter(ctx)

    skills =
      all_skills
      |> filter_query(socket.assigns.search_query)
      |> filter_status(socket.assigns.status_filter)
      |> Enum.sort_by(&String.downcase(&1.name))

    selected_skill =
      case socket.assigns.selected_skill do
        nil -> nil
        selected -> Enum.find(skills, &(&1.id == selected.id))
      end

    assign(socket,
      skills: skills,
      selected_skill: selected_skill,
      stats: compute_stats(all_skills)
    )
  end

  defp filter_query(skills, query) do
    case String.trim(query || "") do
      "" ->
        skills

      query ->
        query = String.downcase(query)

        Enum.filter(skills, fn skill ->
          Enum.any?(
            [skill.name, skill.description, skill.content, Enum.join(skill.tags || [], " ")],
            fn value ->
              String.contains?(String.downcase(value || ""), query)
            end
          )
        end)
    end
  end

  defp filter_status(skills, nil), do: skills
  defp filter_status(skills, status), do: Enum.filter(skills, &(&1.status == status))

  defp compute_stats(skills) do
    Enum.reduce(skills, empty_stats(), fn skill, stats ->
      stats
      |> Map.update!("total", &(&1 + 1))
      |> Map.update(skill.status || "proposed", 1, &(&1 + 1))
    end)
  end

  defp empty_stats, do: %{"total" => 0, "proposed" => 0, "approved" => 0, "rejected" => 0}

  defp skill_meta(%{metadata: meta}, key) when is_map(meta) do
    case Map.get(meta, key) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  defp skill_meta(_, _), do: nil

  defp skill_has_audit?(skill) do
    skill_meta(skill, "audit_status") ||
      skill_meta(skill, "audit_score") ||
      skill_meta(skill, "audit_reasoning")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="skills-governance">
      <section class="account-intro animate-in" aria-labelledby="skills-title">
        <p class="account-kicker" style="font-size: 0.5rem; margin-bottom: 6px;"><span>Knowledge</span> / Skills</p>
        <h2 id="skills-title" style="font-size: 1.3rem; margin-bottom: 6px;">Skills</h2>
        <p style="font-size: 0.82rem;">Reusable workflow guides with step-by-step procedures for repeatable tasks.</p>
      </section>

      <div style="display: flex; gap: 24px; margin-bottom: 20px; flex-wrap: wrap;">
        <.stat_card label="Total" value={@stats["total"]} />
        <.stat_card label="Pending" value={@stats["proposed"]} color="var(--amber)" />
        <.stat_card label="Approved" value={@stats["approved"]} color="var(--green)" />
        <.stat_card label="Rejected" value={@stats["rejected"]} color="var(--muted)" />
      </div>

      <div style="margin-bottom: 16px;">
        <form phx-change="search">
          <input
            name="query"
            type="text"
            class="search-input"
            placeholder="Search skills by name, description, tag, or content..."
            value={@search_query}
            style="width: 100%; padding: 10px 14px; border: 1px solid var(--border); border-radius: var(--radius); background: var(--bg); color: var(--text); font-size: 0.85rem; outline: none;"
          />
        </form>
      </div>

      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px;">
        <div class="filter-tabs">
          <button phx-click="filter-status" phx-value-status="" class={"filter-tab #{if is_nil(@status_filter), do: "active"}"}>All</button>
          <button phx-click="filter-status" phx-value-status="proposed" class={"filter-tab #{if @status_filter == "proposed", do: "active"}"}>Pending</button>
          <button phx-click="filter-status" phx-value-status="approved" class={"filter-tab #{if @status_filter == "approved", do: "active"}"}>Approved</button>
          <button phx-click="filter-status" phx-value-status="rejected" class={"filter-tab #{if @status_filter == "rejected", do: "active"}"}>Rejected</button>
        </div>
        <button phx-click="refresh" class="btn btn-ghost" style="padding: 6px 14px; font-size: 0.72rem;">↻ Refresh</button>
      </div>

      <div style="display: flex; gap: 24px; align-items: flex-start;">
        <div style="flex: 1; display: flex; flex-direction: column; gap: 8px;">
          <%= if Enum.empty?(@skills) do %>
            <div class="card" style="padding: 48px;">
              <div class="empty-state">
                <div class="empty-state-icon">◇</div>
                <p class="empty-state-title">No skills found</p>
                <p class="empty-state-desc">Skill files are managed outside Steward and discovered from the skills directory.</p>
              </div>
            </div>
          <% else %>
            <%= for skill <- @skills do %>
              <div
                phx-click="select-skill"
                phx-value-id={skill.id}
                class={"tool-row #{if @selected_skill && @selected_skill.id == skill.id, do: "selected", else: ""}"}
                style="cursor: pointer;"
              >
                <div style="display: flex; align-items: center; gap: 10px;">
                  <span class={"status-dot status-#{skill.status}"}></span>
                  <span class="category-badge"><%= skill.group %></span>
                  <span style="flex: 1; font-weight: 500; font-size: 0.88rem; color: var(--text);"><%= skill.name %></span>
                  <%= if reviewed = skill_meta(skill, "proposed_by") || skill_meta(skill, "reviewed_by") || skill_meta(skill, "approved_by") do %>
                    <span style="font-size: 0.68rem; color: var(--muted);" title={"By #{reviewed}"}><%= reviewed %></span>
                  <% end %>
                  <%= if audit = skill_meta(skill, "audit_status") do %>
                    <span style="font-size: 0.65rem; padding: 2px 6px; border-radius: 4px; background: var(--bg-elevated); color: var(--muted);">
                      <%= audit %><%= if score = skill_meta(skill, "audit_score"), do: " · #{score}" %>
                    </span>
                  <% end %>
                  <%= for tag <- skill.tags || [] do %><span class="category-badge"><%= tag %></span><% end %>
                </div>
                <%= if skill.description do %>
                  <div style="font-size: 0.78rem; color: var(--text-dim); margin-top: 4px; margin-left: 22px;"><%= skill.description %></div>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>

        <%= if @selected_skill do %>
          <div class="card" style="flex: 0 0 480px; padding: 24px; position: sticky; top: 16px; max-height: calc(100vh - 140px); overflow-y: auto;">
            <div style="display: flex; justify-content: space-between; gap: 16px; align-items: center; margin-bottom: 16px;">
              <div>
                <div class="agent-task-label">Skill · <%= @selected_skill.group %></div>
                <h3 style="font-size: 1.05rem; margin: 4px 0 0; color: var(--text);"><%= @selected_skill.name %></h3>
              </div>
              <%= if @selected_skill.status == "proposed" do %>
                <div style="display: flex; gap: 6px;">
                  <button phx-click="approve" phx-value-id={@selected_skill.id} class="btn btn-primary" style="padding: 6px 14px; font-size: 0.72rem;">✓ Accept</button>
                  <button phx-click="reject" phx-value-id={@selected_skill.id} class="btn btn-danger" style="padding: 6px 14px; font-size: 0.72rem;">✗ Reject</button>
                </div>
              <% end %>
            </div>

            <code style="font-size: 0.7rem; color: var(--muted);"><%= @selected_skill.id %></code>
            <%= if @selected_skill.description do %><p style="font-size: 0.85rem; color: var(--text-dim); line-height: 1.5;"><%= @selected_skill.description %></p><% end %>
            <%= if when_to_use = skill_meta(@selected_skill, "when_to_use") do %>
              <div style="margin: 10px 0; padding: 10px; background: var(--bg); border-radius: var(--radius); font-size: 0.8rem; color: var(--text-dim); line-height: 1.45;">
                <div class="agent-task-label" style="margin-bottom: 4px;">When to use</div>
                <%= when_to_use %>
              </div>
            <% end %>
            <div style="display: flex; gap: 6px; flex-wrap: wrap; margin: 12px 0 12px;">
              <span class="category-badge"><%= @selected_skill.status %></span>
              <%= if audience = skill_meta(@selected_skill, "audience") do %>
                <span class="category-badge"><%= audience %></span>
              <% end %>
              <%= for tag <- @selected_skill.tags || [] do %><span class="category-badge"><%= tag %></span><% end %>
            </div>
            <%= if (@selected_skill.scope_paths || []) != [] do %>
              <div style="margin-bottom: 12px; font-size: 0.72rem; color: var(--muted);">
                Scopes:
                <%= for scope <- @selected_skill.scope_paths do %>
                  <code style="font-size: 0.7rem; margin-left: 6px;"><%= scope %></code>
                <% end %>
              </div>
            <% end %>
            <%= if skill_has_audit?(@selected_skill) do %>
              <div style="margin-bottom: 16px; padding: 10px 12px; background: var(--bg); border: 1px solid var(--border); border-radius: var(--radius);">
                <div class="agent-task-label" style="margin-bottom: 6px;">LLM Audit</div>
                <div style="display: flex; gap: 12px; flex-wrap: wrap; font-size: 0.72rem; color: var(--muted); margin-bottom: 4px;">
                  <%= if status = skill_meta(@selected_skill, "audit_status") do %>
                    <span>Status: <strong style="color: var(--text);"><%= status %></strong></span>
                  <% end %>
                  <%= if score = skill_meta(@selected_skill, "audit_score") do %>
                    <span>Score: <strong style="color: var(--text);"><%= score %></strong></span>
                  <% end %>
                  <%= if at = skill_meta(@selected_skill, "audited_at") do %>
                    <span>Audited: <%= at %></span>
                  <% end %>
                </div>
                <%= if reasoning = skill_meta(@selected_skill, "audit_reasoning") do %>
                  <div style="font-size: 0.78rem; color: var(--text-dim); line-height: 1.45;"><%= reasoning %></div>
                <% end %>
              </div>
            <% end %>
            <div style="display: flex; gap: 12px; flex-wrap: wrap; font-size: 0.72rem; color: var(--muted); margin-bottom: 16px;">
              <%= if proposed_by = skill_meta(@selected_skill, "proposed_by") do %>
                <span>Proposed by: <strong style="color: var(--text);"><%= proposed_by %></strong></span>
              <% end %>
              <%= if reviewed_by = skill_meta(@selected_skill, "reviewed_by") do %>
                <span>Reviewed by: <strong style="color: var(--text);"><%= reviewed_by %></strong></span>
              <% end %>
              <%= if approved_by = skill_meta(@selected_skill, "approved_by") do %>
                <span>Approved by: <strong style="color: var(--text);"><%= approved_by %></strong></span>
              <% end %>
              <%= if rejected_by = skill_meta(@selected_skill, "rejected_by") do %>
                <span>Rejected by: <strong style="color: var(--text);"><%= rejected_by %></strong></span>
              <% end %>
            </div>
            <div class="agent-task-label" style="margin-bottom: 8px;">Instructions (read-only)</div>
            <pre style="white-space: pre-wrap; word-break: break-word; margin: 0; padding: 16px; background: var(--bg); border: 1px solid var(--border); border-radius: var(--radius); color: var(--text-dim); font-family: var(--font-mono); font-size: 0.78rem; line-height: 1.55;"><%= @selected_skill.content %></pre>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :color, :string, default: nil

  defp stat_card(assigns) do
    ~H"""
    <div class="card" style={"padding: 16px 20px; min-width: 110px; #{if @color, do: "border-left: 3px solid #{@color};", else: ""}"}>
      <div class="stat-card-label"><%= @label %></div>
      <div class="stat-card-value"><%= @value %></div>
    </div>
    """
  end
end
