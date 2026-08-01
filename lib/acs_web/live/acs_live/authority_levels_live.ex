defmodule AcsWeb.AcsLive.AuthorityLevelsLive do
  @moduledoc """
  Admin UI for org-defined data authority levels (memory read clearance).
  """

  use AcsWeb, :live_view

  alias Acs.AuthorityLevels

  @impl true
  def mount(_params, _session, socket) do
    org = org_slug(socket)

    socket =
      assign(socket,
        current_path: "/settings/authority-levels",
        org_slug: org,
        levels: AuthorityLevels.list(org),
        form: to_form(%{"label" => "", "sort_order" => ""}, as: :level),
        errors: %{},
        pending_delete: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, url, socket) do
    path = url |> URI.parse() |> Map.get(:path, "/")
    {:noreply, assign(socket, current_path: path)}
  end

  @impl true
  def handle_event("save-level", %{"level" => params}, socket) do
    org = socket.assigns.org_slug

    case AuthorityLevels.upsert(org, params) do
      {:ok, _level} ->
        {:noreply,
         socket
         |> assign(levels: AuthorityLevels.list(org), form: empty_form(), errors: %{})
         |> put_flash(:info, "Authority level saved.")}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         assign(socket,
           form: to_form(params, as: :level),
           errors: Ecto.Changeset.traverse_errors(cs, fn {msg, _} -> msg end)
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, inspect(reason))}
    end
  end

  def handle_event("request-delete-level", %{"slug" => slug}, socket) do
    org = socket.assigns.org_slug

    case AuthorityLevels.delete(org, slug) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(levels: AuthorityLevels.list(org), pending_delete: nil)
         |> put_flash(:info, "Deleted #{slug}.")}

      {:error, :remap_required, info} ->
        {:noreply, assign(socket, pending_delete: info)}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Level not found.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, inspect(reason))}
    end
  end

  def handle_event("cancel-delete-level", _params, socket) do
    {:noreply, assign(socket, pending_delete: nil)}
  end

  def handle_event("confirm-delete-level", %{"slug" => slug, "remap" => remap}, socket) do
    org = socket.assigns.org_slug

    case AuthorityLevels.delete(org, slug, remap: remap) do
      {:ok, result} when is_map(result) ->
        to = get_in(result, [:remapped_to, :label]) || get_in(result, [:remapped_to, :slug])

        {:noreply,
         socket
         |> assign(levels: AuthorityLevels.list(org), pending_delete: nil)
         |> put_flash(:info, "Deleted #{slug}; remapped to #{to}.")}

      {:ok, _} ->
        {:noreply,
         socket
         |> assign(levels: AuthorityLevels.list(org), pending_delete: nil)
         |> put_flash(:info, "Deleted #{slug}.")}

      {:error, reason} when is_binary(reason) ->
        {:noreply, put_flash(socket, :error, reason)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Level not found.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, inspect(reason))}
    end
  end

  defp empty_form, do: to_form(%{"label" => "", "sort_order" => ""}, as: :level)

  defp org_slug(socket) do
    case socket.assigns[:organization] do
      %{slug: slug} when is_binary(slug) -> slug
      _ -> Acs.Org.current()
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="account-shell">
      <section class="account-intro animate-in" aria-labelledby="authority-levels-title">
        <p class="account-kicker"><span>Settings</span> / Data authority</p>
        <h1 id="authority-levels-title" style="font-size: 1.3rem; margin-bottom: 6px;">
          Authority levels
        </h1>
        <p style="font-size: 0.82rem;">
          Org-named clearance bands for knowledge. New memories are stamped with the
          <strong>writer's</strong> clearance. Members read memories at their level and lower.
          Sort order <strong>1</strong> is highest. Up to <%= Acs.AuthorityLevels.max_levels() %> levels.
        </p>
        <p style="margin-top: 10px;">
          <.link navigate={"/settings/members"} id="back-to-members-link" class="btn btn-ghost btn-sm">
            ← Back to members
          </.link>
        </p>
      </section>

      <%= if @pending_delete do %>
        <aside id="authority-delete-remap" class="card" style="padding: 24px; margin-bottom: 24px;">
          <h2 class="section-title" style="margin-bottom: 8px;">Remap before deleting</h2>
          <p style="font-size: 0.82rem; margin-bottom: 12px;">
            <strong><%= @pending_delete.label %></strong> is in use
            (<%= @pending_delete.affected.total %> records: <%= @pending_delete.affected.users %> members,
            <%= @pending_delete.affected.invitations %> invitations,
            <%= @pending_delete.affected.memories %> memories).
            Choose whether to promote or demote them.
          </p>
          <div style="display: flex; flex-wrap: wrap; gap: 8px;">
            <%= if @pending_delete.promote_to do %>
              <button
                id="remap-promote"
                type="button"
                class="btn btn-primary btn-sm"
                phx-click="confirm-delete-level"
                phx-value-slug={@pending_delete.slug}
                phx-value-remap="promote"
              >
                Promote to <%= @pending_delete.promote_to.label %>
              </button>
            <% end %>
            <%= if @pending_delete.demote_to do %>
              <button
                id="remap-demote"
                type="button"
                class="btn btn-primary btn-sm"
                phx-click="confirm-delete-level"
                phx-value-slug={@pending_delete.slug}
                phx-value-remap="demote"
              >
                Demote to <%= @pending_delete.demote_to.label %>
              </button>
            <% end %>
            <button
              id="cancel-delete-level"
              type="button"
              class="btn btn-ghost btn-sm"
              phx-click="cancel-delete-level"
            >
              Cancel
            </button>
          </div>
        </aside>
      <% end %>

      <article class="card" style="padding: 24px; margin-bottom: 24px;">
        <h2 class="section-title" style="margin-bottom: 12px;">Add or update</h2>
        <.form for={@form} id="authority-level-form" phx-submit="save-level">
          <div style="display: flex; flex-wrap: wrap; gap: 12px; align-items: flex-end;">
            <div class="form-field" style="flex: 2; min-width: 180px;">
              <label for="level-label" class="form-label">Label</label>
              <input
                id="level-label"
                type="text"
                name={@form[:label].name}
                value={@form[:label].value}
                class="form-input"
                placeholder="e.g. Field manager"
                required
              />
            </div>
            <div class="form-field" style="flex: 1; min-width: 100px;">
              <label for="level-sort" class="form-label">Sort order</label>
              <input
                id="level-sort"
                type="number"
                min="1"
                name={@form[:sort_order].name}
                value={@form[:sort_order].value}
                class="form-input"
                placeholder="auto"
              />
            </div>
            <button type="submit" class="btn btn-primary">Save level</button>
          </div>
          <%= if map_size(@errors) > 0 do %>
            <p class="field-errors" style="margin-top: 8px;"><%= inspect(@errors) %></p>
          <% end %>
        </.form>
      </article>

      <article class="card" style="padding: 0; overflow: hidden;">
        <table class="requests-table" id="authority-levels-table">
          <thead>
            <tr>
              <th>Order</th>
              <th>Label</th>
              <th>Slug</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            <%= for level <- @levels do %>
              <tr id={"authority-level-#{level.slug}"}>
                <td><%= level.sort_order %></td>
                <td><strong><%= level.label %></strong></td>
                <td><code><%= level.slug %></code></td>
                <td>
                  <button
                    type="button"
                    class="btn btn-danger btn-sm"
                    phx-click="request-delete-level"
                    phx-value-slug={level.slug}
                  >
                    Delete
                  </button>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </article>
    </div>
    """
  end
end
