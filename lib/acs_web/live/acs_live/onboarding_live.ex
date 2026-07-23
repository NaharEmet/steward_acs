defmodule AcsWeb.AcsLive.OnboardingLive do
  @moduledoc """
  Account-host LiveView for creating an organization and following provisioning.
  """

  use AcsWeb, :live_view

  alias Acs.{Accounts, Orgs}

  @slug_regex ~r/^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/
  @reserved_names ~w(account api obsidian www)

  def on_mount(_params, _session, socket) do
    {:cont, assign(socket, current_path: socket.assigns[:current_path] || "/")}
  end

  @impl true
  def mount(_params, _session, socket) do
    attrs = empty_attributes()

    socket =
      socket
      |> assign(
        account_host: true,
        organization: nil,
        provisioning_state: :none,
        self_service_enabled: self_service_enabled?(),
        retry_api: available_retry_api(),
        organization_attrs: attrs,
        form: to_form(attrs, as: :organization),
        errors: %{},
        slug_touched: false,
        subdomain_touched: false
      )
      |> load_organization()

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, url, socket) do
    path = url |> URI.parse() |> Map.get(:path, "/")
    {:noreply, assign(socket, current_path: path)}
  end

  @impl true
  def handle_event("validate", %{"organization" => params} = payload, socket) do
    target = get_in(payload, ["_target"]) || []
    {attrs, slug_touched, subdomain_touched} = merge_derived_fields(socket, params, target)

    {:noreply,
     socket
     |> assign(slug_touched: slug_touched, subdomain_touched: subdomain_touched)
     |> assign_form(attrs, validate_attributes(attrs))}
  end

  def handle_event("create-organization", %{"organization" => params}, socket) do
    attrs = normalize_attributes(params)
    errors = validate_attributes(attrs)

    cond do
      socket.assigns.organization ->
        {:noreply,
         socket
         |> put_flash(:info, "Your organization has already been created.")
         |> load_organization()}

      not socket.assigns.self_service_enabled ->
        {:noreply,
         put_flash(socket, :error, "Self-service organization creation is not enabled.")}

      map_size(errors) > 0 ->
        {:noreply, assign_form(socket, attrs, errors)}

      true ->
        create_organization(socket, attrs)
    end
  end

  def handle_event("retry-provisioning", _params, socket) do
    socket = load_organization(socket)

    case {socket.assigns.organization, socket.assigns.retry_api} do
      {nil, _} ->
        {:noreply, put_flash(socket, :error, "No organization is assigned to this account.")}

      {_organization, nil} ->
        {:noreply, load_organization(socket)}

      {organization, retry_api} ->
        retry_provisioning(socket, organization, retry_api)
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_organization(socket)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp create_organization(socket, attrs) do
    case Orgs.create_for_user(socket.assigns.current_user, attrs) do
      {:ok, organization} ->
        state = provisioning_state(organization)

        message =
          case state do
            :ready -> "Organization created. Your Steward workspace is ready."
            :failed -> "Organization created, but workspace provisioning needs attention."
            _ -> "Organization created. Steward is preparing your workspace."
          end

        {:noreply,
         socket
         |> assign(errors: %{})
         |> refresh_account_context()
         |> put_flash(:info, message)}

      {:error, reason} ->
        errors = field_errors(reason)
        socket = assign_form(socket, attrs, errors)

        if map_size(errors) == 0 do
          {:noreply, put_flash(socket, :error, creation_error_message(reason))}
        else
          {:noreply, socket}
        end
    end
  end

  defp retry_provisioning(socket, organization, {function, 2}) do
    case apply(Orgs, function, [socket.assigns.current_user, organization]) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(organization: updated, provisioning_state: provisioning_state(updated))
         |> put_flash(:info, "Workspace provisioning has been queued again.")}

      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Workspace provisioning has been queued again.")
         |> load_organization()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, retry_error_message(reason))}

      _other ->
        {:noreply, put_flash(socket, :error, "Steward could not retry provisioning.")}
    end
  end

  defp retry_provisioning(socket, organization, {function, 1}) do
    case apply(Orgs, function, [organization]) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(organization: updated, provisioning_state: provisioning_state(updated))
         |> put_flash(:info, "Workspace provisioning has been queued again.")}

      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Workspace provisioning has been queued again.")
         |> load_organization()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, retry_error_message(reason))}

      _other ->
        {:noreply, put_flash(socket, :error, "Steward could not retry provisioning.")}
    end
  end

  defp load_organization(socket), do: refresh_account_context(socket)

  defp refresh_account_context(socket) do
    current_user = reload_current_user(socket.assigns[:current_user])

    organization =
      current_user
      |> Accounts.organization_for_user()
      |> normalize_organization()

    assign(socket,
      current_user: current_user,
      organization: organization,
      provisioning_state: provisioning_state(organization),
      retry_api: available_retry_api()
    )
  end

  defp reload_current_user(%{id: id}) when not is_nil(id), do: Accounts.get_user!(id)
  defp reload_current_user(user), do: user

  defp normalize_organization({:ok, organization}), do: organization
  defp normalize_organization({:error, _reason}), do: nil
  defp normalize_organization(organization), do: organization

  defp provisioning_state(nil), do: :none

  defp provisioning_state(organization) do
    case organization
         |> field(:provisioning_status, "ready")
         |> to_string()
         |> String.downcase() do
      status when status in ["ready", "active", "provisioned"] -> :ready
      status when status in ["failed", "error"] -> :failed
      _status -> :pending
    end
  end

  defp merge_derived_fields(socket, params, target) do
    attrs = Map.merge(socket.assigns.organization_attrs, stringify_keys(params))
    target_field = List.last(target)
    slug_touched = socket.assigns.slug_touched or target_field == "slug"
    subdomain_touched = socket.assigns.subdomain_touched or target_field == "subdomain"

    attrs =
      case target_field do
        "name" ->
          derived = slugify(attrs["name"])

          attrs
          |> maybe_put_derived("slug", derived, slug_touched)
          |> maybe_put_derived("subdomain", derived, subdomain_touched)

        "slug" ->
          slug = normalize_identifier(attrs["slug"])

          attrs
          |> Map.put("slug", slug)
          |> maybe_put_derived("subdomain", slug, subdomain_touched)

        "subdomain" ->
          Map.update(attrs, "subdomain", "", &normalize_identifier/1)

        _other ->
          attrs
      end

    {attrs, slug_touched, subdomain_touched}
  end

  defp maybe_put_derived(attrs, _key, _value, true), do: attrs
  defp maybe_put_derived(attrs, key, value, false), do: Map.put(attrs, key, value)

  defp normalize_attributes(params) do
    params
    |> stringify_keys()
    |> Map.take(~w(name slug subdomain))
    |> Map.update("name", "", &String.trim/1)
    |> Map.update("slug", "", &normalize_identifier/1)
    |> Map.update("subdomain", "", &normalize_identifier/1)
  end

  defp normalize_identifier(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
  end

  defp normalize_identifier(_value), do: ""

  defp validate_attributes(attrs) do
    %{}
    |> validate_name(Map.get(attrs, "name", ""))
    |> validate_identifier(:slug, Map.get(attrs, "slug", ""))
    |> validate_identifier(:subdomain, Map.get(attrs, "subdomain", ""))
  end

  defp validate_name(errors, name) do
    name = String.trim(name || "")

    cond do
      name == "" -> add_error(errors, :name, "Enter an organization name.")
      String.length(name) > 160 -> add_error(errors, :name, "Use 160 characters or fewer.")
      true -> errors
    end
  end

  defp validate_identifier(errors, field_name, value) do
    value = value || ""

    cond do
      value == "" ->
        add_error(errors, field_name, "This field is required.")

      value in @reserved_names ->
        add_error(errors, field_name, "This address is reserved.")

      not Regex.match?(@slug_regex, value) ->
        add_error(
          errors,
          field_name,
          "Use lowercase letters, numbers, and single hyphens; start and end with a letter or number."
        )

      true ->
        errors
    end
  end

  defp add_error(errors, field_name, message) do
    Map.update(errors, field_name, [message], &[message | &1])
  end

  defp assign_form(socket, attrs, errors) do
    assign(socket,
      organization_attrs: attrs,
      form: to_form(attrs, as: :organization),
      errors: errors
    )
  end

  defp field_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, rendered ->
        String.replace(rendered, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp field_errors(errors) when is_list(errors) do
    Enum.reduce(errors, %{}, fn
      {field_name, {message, _options}}, acc when is_atom(field_name) and is_binary(message) ->
        add_error(acc, field_name, message)

      {field_name, message}, acc when is_atom(field_name) and is_binary(message) ->
        add_error(acc, field_name, message)

      _error, acc ->
        acc
    end)
  end

  defp field_errors(_reason), do: %{}

  defp creation_error_message(:already_in_organization),
    do: "This account already belongs to an organization. Refresh to continue."

  defp creation_error_message(:rate_limited),
    do: "Organization creation is temporarily limited. Please try again later."

  defp creation_error_message(_reason),
    do: "Steward could not create the organization. Review the details and try again."

  defp retry_error_message(:unauthorized),
    do: "Only an organization owner can retry provisioning."

  defp retry_error_message(:forbidden), do: "Only an organization owner can retry provisioning."
  defp retry_error_message(_reason), do: "Steward could not retry provisioning. Please try again."

  defp available_retry_api do
    Code.ensure_loaded?(Orgs)

    cond do
      function_exported?(Orgs, :retry_provisioning, 2) -> {:retry_provisioning, 2}
      function_exported?(Orgs, :retry_provisioning, 1) -> {:retry_provisioning, 1}
      true -> nil
    end
  end

  defp self_service_enabled? do
    Application.get_env(:steward_acs, :self_service_orgs_enabled, false) == true
  end

  defp empty_attributes, do: %{"name" => "", "slug" => "", "subdomain" => ""}

  defp stringify_keys(params) do
    Map.new(params, fn {key, value} -> {to_string(key), value} end)
  end

  defp slugify(value) do
    value
    |> to_string()
    |> String.normalize(:nfd)
    |> String.replace(~r/[\p{Mn}]/u, "")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> String.slice(0, 63)
    |> String.trim_trailing("-")
  end

  defp field(record, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(record, key, default) when is_map(record) do
    Map.get(record, key, Map.get(record, Atom.to_string(key), default))
  end

  defp field(_record, _key, default), do: default

  @impl true
  def render(assigns) do
    ~H"""
    <section id="onboarding-live" class="account-shell account-shell-narrow">
      <div class="account-intro animate-in">
        <p class="account-kicker"><span>Account desk</span> / Organization setup</p>
        <h1>Give Steward a place to work.</h1>
        <p>
          Your organization becomes the permanent boundary for Steward's tools, memory, and operating context.
        </p>
      </div>

      <div class="signal-rail animate-in delay-1" aria-label="Organization setup progress">
        <div class="signal-step is-complete"><span>01</span> Identity verified</div>
        <div class={"signal-step #{if @organization, do: "is-complete", else: "is-active"}"}>
          <span>02</span> Organization
        </div>
        <div class={"signal-step #{if @provisioning_state == :ready, do: "is-complete", else: if(@organization, do: "is-active", else: "")}"}>
          <span>03</span> Workspace ready
        </div>
      </div>

      <%= if @organization do %>
        <article id="provisioning-status" class={"card account-card status-panel status-#{@provisioning_state} animate-in delay-2"} aria-live="polite">
          <div class="status-emblem" aria-hidden="true">
            <%= case @provisioning_state do %>
              <% :ready -> %>✓
              <% :failed -> %>!
              <% _pending -> %>↻
            <% end %>
          </div>

          <div class="status-copy">
            <p class="account-kicker">Workspace status</p>
            <%= case @provisioning_state do %>
              <% :ready -> %>
                <h2>Your workspace is ready.</h2>
                <p>
                  <strong><%= field(@organization, :name, "Your organization") %></strong>
                  is provisioned as
                  <code><%= field(@organization, :slug, "") %></code>. Continue to Steward to begin operating in this organization.
                </p>
                <div class="account-actions">
                  <.link id="onboarding-continue" href="/auth/log_in" class="btn btn-primary">
                    Open workspace <span aria-hidden="true">→</span>
                  </.link>
                </div>

              <% :failed -> %>
                <h2>Provisioning needs attention.</h2>
                <p>
                  Your organization record is safe. Steward could not finish preparing the workspace.
                </p>
                <%= if error = field(@organization, :provisioning_error) do %>
                  <p id="provisioning-error" class="status-detail"><%= error %></p>
                <% end %>
                <div class="account-actions">
                  <button id="retry-provisioning" type="button" phx-click="retry-provisioning" class="btn btn-primary">
                    <%= if @retry_api, do: "Retry provisioning", else: "Refresh status" %>
                  </button>
                  <span class="form-hint">If this persists, contact your Steward operator.</span>
                </div>

              <% _pending -> %>
                <h2>Preparing your workspace.</h2>
                <p>
                  Steward is creating the isolated directories and services for
                  <strong><%= field(@organization, :name, "your organization") %></strong>.
                </p>
                <div class="account-actions">
                  <button id="refresh-provisioning" type="button" phx-click="refresh" class="btn btn-ghost">
                    ↻ Refresh status
                  </button>
                  <span class="form-hint">You can safely leave this page and return later.</span>
                </div>
            <% end %>
          </div>
        </article>
      <% else %>
        <%= if @self_service_enabled do %>
          <article class="card account-card animate-in delay-2">
            <div class="account-card-heading">
              <div>
                <p class="account-kicker">New organization</p>
                <h2>Set the operating identity</h2>
              </div>
              <span class="coordinate-mark" aria-hidden="true">ORG / 001</span>
            </div>

            <.form for={@form} id="onboarding-form" phx-change="validate" phx-submit="create-organization" novalidate>
              <div class="form-stack">
                <div class="form-field">
                  <label for="organization-name" class="form-label">Organization name</label>
                  <input
                    id="organization-name"
                    name={@form[:name].name}
                    value={@form[:name].value}
                    type="text"
                    class="form-control"
                    autocomplete="organization"
                    maxlength="160"
                    placeholder="Northstar Studio"
                    aria-invalid={Map.has_key?(@errors, :name)}
                    aria-describedby="organization-name-hint organization-name-errors"
                  />
                  <p id="organization-name-hint" class="form-hint">The human-readable name shown across Steward.</p>
                  <div id="organization-name-errors" class="field-errors" aria-live="polite">
                    <%= for message <- Map.get(@errors, :name, []) do %>
                      <p><%= message %></p>
                    <% end %>
                  </div>
                </div>

                <div class="form-grid">
                  <div class="form-field">
                    <label for="organization-slug" class="form-label">Organization slug</label>
                    <input
                      id="organization-slug"
                      name={@form[:slug].name}
                      value={@form[:slug].value}
                      type="text"
                      class="form-control mono"
                      maxlength="63"
                      placeholder="northstar-studio"
                      spellcheck="false"
                      autocapitalize="none"
                      aria-invalid={Map.has_key?(@errors, :slug)}
                      aria-describedby="organization-slug-hint organization-slug-errors"
                    />
                    <p id="organization-slug-hint" class="form-hint">Permanent identity used for tenant-scoped data.</p>
                    <div id="organization-slug-errors" class="field-errors" aria-live="polite">
                      <%= for message <- Map.get(@errors, :slug, []) do %>
                        <p><%= message %></p>
                      <% end %>
                    </div>
                  </div>

                  <div class="form-field">
                    <label for="organization-subdomain" class="form-label">Workspace address</label>
                    <input
                      id="organization-subdomain"
                      name={@form[:subdomain].name}
                      value={@form[:subdomain].value}
                      type="text"
                      class="form-control mono"
                      maxlength="63"
                      placeholder="northstar-studio"
                      spellcheck="false"
                      autocapitalize="none"
                      aria-invalid={Map.has_key?(@errors, :subdomain)}
                      aria-describedby="organization-subdomain-hint organization-subdomain-errors"
                    />
                    <p id="organization-subdomain-hint" class="form-hint">The tenant address used to open this workspace.</p>
                    <div id="organization-subdomain-errors" class="field-errors" aria-live="polite">
                      <%= for message <- Map.get(@errors, :subdomain, []) do %>
                        <p><%= message %></p>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>

              <div class="form-footer">
                <p>
                  Slug and address are permanent in this release. Review both before continuing.
                </p>
                <button id="onboarding-submit" type="submit" class="btn btn-primary" phx-disable-with="Creating organization…">
                  Create organization <span aria-hidden="true">→</span>
                </button>
              </div>
            </.form>
          </article>
        <% else %>
          <article id="onboarding-disabled" class="card account-card status-panel status-pending animate-in delay-2">
            <div class="status-emblem" aria-hidden="true">◇</div>
            <div class="status-copy">
              <p class="account-kicker">Invitation required</p>
              <h2>Self-service setup is closed.</h2>
              <p>
                Ask an organization owner to invite <strong><%= @current_user.email %></strong>, then return using the invitation link.
              </p>
            </div>
          </article>
        <% end %>
      <% end %>
    </section>
    """
  end
end
