defmodule AcsWeb.AcsLive.SkillsLive do
  @moduledoc """
  LiveView for browsing and managing the file-backed skill library.
  """

  use AcsWeb, :live_view

  alias Acs.Skills.Auditor
  alias Acs.Skills.Store

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
        form_mode: nil,
        form: empty_form(),
        audit_stats: empty_audit_stats()
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
  def handle_event("search", %{"query" => query}, socket) do
    {:noreply,
     socket
     |> assign(search_query: query, selected_skill: nil, form_mode: nil)
     |> load_data()}
  end

  def handle_event("select-skill", %{"name" => name}, socket) do
    case Store.get_skill(name) do
      nil -> {:noreply, put_flash(socket, :error, "Skill '#{name}' was not found")}
      skill -> {:noreply, assign(socket, selected_skill: skill, form_mode: nil)}
    end
  end

  def handle_event("new-skill", _params, socket) do
    {:noreply, assign(socket, selected_skill: nil, form_mode: :new, form: empty_form())}
  end

  def handle_event("edit-skill", _params, %{assigns: %{selected_skill: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_event("edit-skill", _params, socket) do
    skill = socket.assigns.selected_skill

    form = %{
      "name" => skill.name,
      "description" => skill.description || "",
      "tags" => Enum.join(skill.tags || [], ", "),
      "content" => skill.content || ""
    }

    {:noreply, assign(socket, form_mode: :edit, form: form)}
  end

  def handle_event("cancel-form", _params, socket) do
    {:noreply, assign(socket, form_mode: nil)}
  end

  def handle_event("save-skill", %{"skill" => params}, socket) do
    name = String.trim(params["name"] || "")
    description = blank_to_nil(params["description"])
    content = params["content"] || ""
    tags = parse_tags(params["tags"])
    form = Map.take(params, ~w(name description tags content))

    cond do
      name == "" ->
        {:noreply,
         socket
         |> assign(form: form)
         |> put_flash(:error, "Name is required")}

      String.trim(content) == "" ->
        {:noreply,
         socket
         |> assign(form: form)
         |> put_flash(:error, "Content is required")}

      socket.assigns.form_mode == :new && Store.get_skill(name) != nil ->
        {:noreply,
         socket
         |> assign(form: form)
         |> put_flash(:error, "A skill named '#{name}' already exists")}

      socket.assigns.form_mode == :edit && !Store.writable_skill?(name) ->
        {:noreply,
         socket
         |> assign(form: form)
         |> put_flash(:error, "Built-in skill '#{name}' is read-only in this deployment")}

      true ->
        case Store.save_skill(name, content, tags, description) do
          {:ok, _} ->
            skill = Store.get_skill(name)

            {:noreply,
             socket
             |> assign(selected_skill: skill, form_mode: nil)
             |> put_flash(:info, "Skill '#{name}' saved")
             |> load_data()}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(form: form)
             |> put_flash(:error, "Failed to save skill: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("delete-skill", %{"name" => name}, socket) do
    case Store.delete_skill(name) do
      :ok ->
        {:noreply,
         socket
         |> assign(selected_skill: nil, form_mode: nil)
         |> put_flash(:info, "Skill '#{name}' deleted")
         |> load_data()}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Skill '#{name}' was not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete skill: #{inspect(reason)}")}
    end
  end

  def handle_event("run-audit", _params, socket) do
    writable_skills = Enum.filter(Store.list_skills(), &Store.writable_skill?(&1["name"]))
    results = Auditor.audit_all(writable_skills)
    skipped = socket.assigns.audit_stats.total - length(writable_skills)

    message =
      "Audited #{length(results)} skills" <>
        if skipped > 0, do: "; skipped #{skipped} read-only built-ins", else: ""

    {:noreply,
     socket
     |> put_flash(:info, message)
     |> load_data()}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_data(socket)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load_data(socket) do
    skills =
      case String.trim(socket.assigns.search_query) do
        "" -> Store.list_skills() |> Enum.map(&Store.get_skill(&1["name"]))
        query -> Store.search_skills(query)
      end
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&String.downcase(&1.name))

    selected_skill =
      case socket.assigns.selected_skill do
        nil -> nil
        selected -> Enum.find(skills, &(&1.name == selected.name))
      end

    assign(socket,
      skills: skills,
      selected_skill: selected_skill,
      audit_stats: compute_audit_stats()
    )
  end

  defp compute_audit_stats do
    Store.list_skills()
    |> Enum.reduce(empty_audit_stats(), fn meta, stats ->
      status = meta["audit_status"]

      stats
      |> Map.update!(:total, &(&1 + 1))
      |> maybe_increment_status(status)
    end)
  end

  defp maybe_increment_status(stats, "ok"), do: Map.update!(stats, :ok, &(&1 + 1))

  defp maybe_increment_status(stats, status) when status in ["needs_improvement", "failing"],
    do: Map.update!(stats, :attention, &(&1 + 1))

  defp maybe_increment_status(stats, _status), do: Map.update!(stats, :unaudited, &(&1 + 1))

  defp empty_audit_stats, do: %{total: 0, ok: 0, attention: 0, unaudited: 0}

  defp empty_form,
    do: %{"name" => "", "description" => "", "tags" => "", "content" => ""}

  defp parse_tags(nil), do: []

  defp parse_tags(tags) do
    tags
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp audit_status(skill) do
    Store.list_skills()
    |> Enum.find_value(fn meta ->
      if meta["name"] == skill.name, do: meta["audit_status"]
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="skills-management">
      <div style="display: flex; gap: 24px; margin-bottom: 20px; flex-wrap: wrap;">
        <.stat_card label="Total" value={@audit_stats.total} />
        <.stat_card label="Passing" value={@audit_stats.ok} color="var(--green)" />
        <.stat_card label="Needs attention" value={@audit_stats.attention} color="var(--amber)" />
        <.stat_card label="Unaudited" value={@audit_stats.unaudited} color="var(--muted)" />
      </div>

      <div style="display: flex; gap: 12px; margin-bottom: 16px; align-items: center;">
        <form phx-change="search" style="flex: 1;">
          <input
            name="query"
            type="text"
            class="search-input"
            placeholder="Search skills by name, description, tag, or content..."
            value={@search_query}
            style="width: 100%; padding: 10px 14px; border: 1px solid var(--border); border-radius: var(--radius); background: var(--bg); color: var(--text); font-size: 0.85rem; outline: none;"
          />
        </form>
        <button phx-click="run-audit" class="btn btn-ghost" style="padding: 8px 14px; font-size: 0.72rem;">
          ✓ Audit all
        </button>
        <button phx-click="new-skill" class="btn btn-primary" style="padding: 8px 14px; font-size: 0.72rem;">
          + New skill
        </button>
      </div>

      <div style="display: flex; gap: 24px; align-items: flex-start;">
        <div style="flex: 1; display: flex; flex-direction: column; gap: 8px;">
          <%= if Enum.empty?(@skills) do %>
            <div class="card" style="padding: 48px;">
              <div class="empty-state">
                <div class="empty-state-icon">◇</div>
                <p class="empty-state-title">
                  <%= if @search_query == "", do: "No skills found", else: "No skills match your search" %>
                </p>
                <p class="empty-state-desc">Create a skill to give agents reusable workflow guidance.</p>
              </div>
            </div>
          <% else %>
            <%= for skill <- @skills do %>
              <div
                phx-click="select-skill"
                phx-value-name={skill.name}
                class={"tool-row #{if @selected_skill && @selected_skill.name == skill.name, do: "selected", else: ""}"}
                style="cursor: pointer;"
              >
                <div style="display: flex; align-items: center; gap: 10px;">
                  <span class={"status-dot status-#{audit_status(skill) || "unknown"}"}></span>
                  <span style="flex: 1; font-weight: 500; font-size: 0.88rem; color: var(--text);"><%= skill.name %></span>
                  <%= for tag <- skill.tags || [] do %>
                    <span class="category-badge"><%= tag %></span>
                  <% end %>
                </div>
                <%= if skill.description do %>
                  <div style="font-size: 0.78rem; color: var(--text-dim); margin-top: 4px; margin-left: 22px;">
                    <%= skill.description %>
                  </div>
                <% end %>
              </div>
            <% end %>
          <% end %>
        </div>

        <%= if @form_mode do %>
          <.skill_form mode={@form_mode} form={@form} />
        <% else %>
          <%= if @selected_skill do %>
            <div class="card" style="flex: 0 0 480px; padding: 24px; position: sticky; top: 16px; max-height: calc(100vh - 140px); overflow-y: auto;">
              <div style="display: flex; justify-content: space-between; gap: 16px; align-items: center; margin-bottom: 16px;">
                <div>
                  <div class="agent-task-label">Skill</div>
                  <h3 style="font-size: 1.05rem; margin: 4px 0 0; color: var(--text);"><%= @selected_skill.name %></h3>
                </div>
                <%= if Store.writable_skill?(@selected_skill.name) do %>
                  <div style="display: flex; gap: 6px;">
                    <button phx-click="edit-skill" class="btn btn-primary" style="padding: 6px 14px; font-size: 0.72rem;">Edit</button>
                    <button
                      phx-click="delete-skill"
                      phx-value-name={@selected_skill.name}
                      data-confirm={"Delete skill '#{@selected_skill.name}'?"}
                      class="btn btn-danger"
                      style="padding: 6px 14px; font-size: 0.72rem;"
                    >Delete</button>
                  </div>
                <% else %>
                  <span class="category-badge">Read-only built-in</span>
                <% end %>
              </div>

              <%= if @selected_skill.description do %>
                <p style="font-size: 0.85rem; color: var(--text-dim); line-height: 1.5;"><%= @selected_skill.description %></p>
              <% end %>

              <div style="display: flex; gap: 6px; flex-wrap: wrap; margin: 12px 0 18px;">
                <%= for tag <- @selected_skill.tags || [] do %>
                  <span class="category-badge"><%= tag %></span>
                <% end %>
              </div>

              <div class="agent-task-label" style="margin-bottom: 8px;">Instructions</div>
              <pre style="white-space: pre-wrap; word-break: break-word; margin: 0; padding: 16px; background: var(--bg); border: 1px solid var(--border); border-radius: var(--radius); color: var(--text-dim); font-family: var(--font-mono); font-size: 0.78rem; line-height: 1.55;"><%= @selected_skill.content %></pre>
            </div>
          <% end %>
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

  attr :mode, :atom, required: true
  attr :form, :map, required: true

  defp skill_form(assigns) do
    ~H"""
    <div class="card" style="flex: 0 0 480px; padding: 24px; position: sticky; top: 16px;">
      <h3 style="font-size: 1rem; margin: 0 0 18px; color: var(--text);">
        <%= if @mode == :new, do: "Create skill", else: "Edit skill" %>
      </h3>
      <form phx-submit="save-skill">
        <label class="agent-task-label" for="skill-name">Name</label>
        <input
          id="skill-name"
          name="skill[name]"
          value={@form["name"]}
          readonly={@mode == :edit}
          required
          style="width: 100%; margin: 6px 0 14px; padding: 9px 12px; border: 1px solid var(--border); border-radius: var(--radius); background: var(--bg); color: var(--text);"
        />

        <label class="agent-task-label" for="skill-description">Description</label>
        <input
          id="skill-description"
          name="skill[description]"
          value={@form["description"]}
          placeholder="What this skill helps an agent do"
          style="width: 100%; margin: 6px 0 14px; padding: 9px 12px; border: 1px solid var(--border); border-radius: var(--radius); background: var(--bg); color: var(--text);"
        />

        <label class="agent-task-label" for="skill-tags">Tags</label>
        <input
          id="skill-tags"
          name="skill[tags]"
          value={@form["tags"]}
          placeholder="workflow, deployment, operations"
          style="width: 100%; margin: 6px 0 14px; padding: 9px 12px; border: 1px solid var(--border); border-radius: var(--radius); background: var(--bg); color: var(--text);"
        />

        <label class="agent-task-label" for="skill-content">Instructions (Markdown)</label>
        <textarea
          id="skill-content"
          name="skill[content]"
          required
          rows="18"
          style="width: 100%; resize: vertical; margin: 6px 0 16px; padding: 12px; border: 1px solid var(--border); border-radius: var(--radius); background: var(--bg); color: var(--text); font-family: var(--font-mono); font-size: 0.78rem; line-height: 1.5;"
        ><%= @form["content"] %></textarea>

        <div style="display: flex; justify-content: flex-end; gap: 8px;">
          <button type="button" phx-click="cancel-form" class="btn btn-ghost">Cancel</button>
          <button type="submit" class="btn btn-primary">Save skill</button>
        </div>
      </form>
    </div>
    """
  end
end
