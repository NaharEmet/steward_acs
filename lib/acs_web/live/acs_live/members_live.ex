defmodule AcsWeb.AcsLive.MembersLive do
  @moduledoc """
  Tenant LiveView for organization member and invitation administration.
  """

  use AcsWeb, :live_view

  alias Acs.Accounts

  @roles ~w(member admin owner)
  @email_regex ~r/^[^\s]+@[^\s]+\.[^\s]+$/

  def on_mount(_params, _session, socket) do
    {:cont, assign(socket, current_path: socket.assigns[:current_path] || "/")}
  end

  @impl true
  def mount(_params, _session, socket) do
    attrs = empty_invitation_attrs()

    socket =
      assign(socket,
        organization: nil,
        members: [],
        pending_invitations: [],
        current_role: nil,
        invitation_attrs: attrs,
        invitation_form:
          to_form(%{"email" => attrs.email, "role" => attrs.role}, as: :invitation),
        invitation_errors: %{},
        invitation_link: nil
      )

    case authorize_admin(socket) do
      {:ok, socket} ->
        {:ok, load_data(socket)}

      {:error, socket} ->
        {:ok,
         socket
         |> put_flash(:error, "Organization administrator access is required.")
         |> redirect(to: "/")}
    end
  end

  @impl true
  def handle_params(_params, url, socket) do
    path = url |> URI.parse() |> Map.get(:path, "/")
    {:noreply, assign(socket, current_path: path)}
  end

  @impl true
  def handle_event("validate-invitation", %{"invitation" => params}, socket) do
    attrs = normalize_invitation_attrs(params)
    errors = validate_invitation(attrs, allowed_invite_roles(socket))
    {:noreply, assign_invitation_form(socket, attrs, errors)}
  end

  def handle_event("invite-member", %{"invitation" => params}, socket) do
    with_admin(socket, fn socket ->
      attrs = normalize_invitation_attrs(params)
      errors = validate_invitation(attrs, allowed_invite_roles(socket))

      if map_size(errors) > 0 do
        {:noreply, assign_invitation_form(socket, attrs, errors)}
      else
        case Accounts.invite_user(socket.assigns.current_user, attrs) do
          {:ok, invitation, raw_token} when is_binary(raw_token) ->
            reset = empty_invitation_attrs()

            {:noreply,
             socket
             |> assign_invitation_form(reset, %{})
             |> reveal_invitation_link(invitation, raw_token, :created)
             |> load_data()}

          {:error, reason} ->
            invitation_mutation_error(socket, attrs, reason)

          _other ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "The invitation was not created with a shareable link. Please try again."
             )}
        end
      end
    end)
  end

  def handle_event("resend-invitation", %{"id" => id}, socket) do
    with_admin(socket, fn socket ->
      case resolve_invitation_id(socket.assigns.pending_invitations, id) do
        nil ->
          {:noreply, put_flash(socket, :error, "That pending invitation no longer exists.")}

        invitation_id ->
          case Accounts.resend_invitation(socket.assigns.current_user, invitation_id) do
            {:ok, invitation, raw_token} when is_binary(raw_token) ->
              {:noreply,
               socket
               |> reveal_invitation_link(invitation, raw_token, :rotated)
               |> load_data()}

            {:error, reason} ->
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 context_error_message(reason, "create a new invitation link")
               )}

            _other ->
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 "Steward could not create a new invitation link. Please try again."
               )}
          end
      end
    end)
  end

  def handle_event("revoke-invitation", %{"id" => id}, socket) do
    with_admin(socket, fn socket ->
      case resolve_invitation_id(socket.assigns.pending_invitations, id) do
        nil ->
          {:noreply, put_flash(socket, :error, "That pending invitation no longer exists.")}

        invitation_id ->
          mutate_and_reload(
            socket,
            Accounts.revoke_invitation(socket.assigns.current_user, invitation_id),
            "Invitation revoked.",
            "revoke the invitation"
          )
      end
    end)
  end

  def handle_event("change-role", %{"target_id" => id, "role" => role}, socket) do
    with_admin(socket, fn socket ->
      target_id = resolve_member_id(socket.assigns.members, id)

      cond do
        is_nil(target_id) ->
          {:noreply,
           put_flash(socket, :error, "That member no longer belongs to this organization.")}

        role not in @roles ->
          {:noreply, put_flash(socket, :error, "Choose a valid organization role.")}

        true ->
          mutate_and_reload(
            socket,
            Accounts.change_role(socket.assigns.current_user, target_id, role),
            "Member role changed to #{role}.",
            "change that member's role"
          )
      end
    end)
  end

  def handle_event("remove-member", %{"id" => id}, socket) do
    with_admin(socket, fn socket ->
      case resolve_member_id(socket.assigns.members, id) do
        nil ->
          {:noreply,
           put_flash(socket, :error, "That member no longer belongs to this organization.")}

        target_id ->
          mutate_and_reload(
            socket,
            Accounts.remove_member(socket.assigns.current_user, target_id),
            "Member removed from the organization.",
            "remove that member"
          )
      end
    end)
  end

  def handle_event("refresh", _params, socket) do
    with_admin(socket, fn socket -> {:noreply, load_data(socket)} end)
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp with_admin(socket, function) do
    case authorize_admin(socket) do
      {:ok, socket} ->
        function.(load_data(socket))

      {:error, socket} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Your organization permissions changed. Administrator access is required."
         )
         |> push_navigate(to: "/")}
    end
  end

  defp authorize_admin(socket) do
    current_user = reload_current_user(socket.assigns[:current_user])
    organization = current_organization(current_user)
    socket = assign(socket, current_user: current_user, organization: organization)

    if organization && Accounts.authorized_admin?(current_user, organization) do
      {:ok, socket}
    else
      {:error, socket}
    end
  end

  defp reload_current_user(%{id: id}) when not is_nil(id), do: Accounts.get_user!(id)
  defp reload_current_user(user), do: user

  defp current_organization(nil), do: nil

  defp current_organization(user) do
    case Accounts.organization_for_user(user) do
      {:ok, organization} -> organization
      {:error, _reason} -> nil
      organization -> organization
    end
  end

  defp load_data(%{assigns: %{organization: nil}} = socket), do: socket

  defp load_data(socket) do
    {members, member_error} =
      normalize_collection(Accounts.list_members(socket.assigns.organization))

    {pending_invitations, invitation_error} =
      normalize_collection(Accounts.list_pending_invitations(socket.assigns.organization))

    current_role = current_user_role(socket.assigns.current_user, members)

    socket =
      assign(socket,
        members: members,
        pending_invitations: pending_invitations,
        current_role: current_role
      )

    cond do
      member_error -> put_flash(socket, :error, "Steward could not load organization members.")
      invitation_error -> put_flash(socket, :error, "Steward could not load pending invitations.")
      true -> socket
    end
  end

  defp normalize_collection({:ok, records}) when is_list(records), do: {records, nil}
  defp normalize_collection(records) when is_list(records), do: {records, nil}
  defp normalize_collection({:error, reason}), do: {[], reason}
  defp normalize_collection(_other), do: {[], :invalid_response}

  defp reveal_invitation_link(socket, invitation, raw_token, action) do
    invitation_link = %{
      id: invitation_id(invitation),
      email: invitation_email(invitation),
      expires_at: field(invitation, :expires_at),
      url: account_invitation_url(raw_token)
    }

    message =
      case action do
        :rotated ->
          "A new invitation link is ready. Copy it below; the previous link no longer works."

        _created ->
          "Invitation created. Copy the link below to share it securely."
      end

    socket
    |> assign(invitation_link: invitation_link)
    |> put_flash(:info, message)
  end

  defp account_invitation_url(raw_token) do
    endpoint_config = Application.get_env(:steward_acs, AcsWeb.Endpoint, [])
    url_config = Keyword.get(endpoint_config, :url, [])
    scheme = normalize_url_scheme(Keyword.get(url_config, :scheme))
    host = configured_account_host(url_config)

    port =
      url_config
      |> Keyword.get(:port)
      |> then(&(&1 || listener_port(endpoint_config, scheme)))
      |> normalize_url_port(scheme)

    %URI{
      scheme: scheme,
      host: host,
      port: port,
      path: "/invitations/" <> URI.encode(raw_token)
    }
    |> URI.to_string()
  end

  defp configured_account_host(url_config) do
    account_host = Application.get_env(:steward_acs, :account_host)
    endpoint_host = Keyword.get(url_config, :host)

    Enum.find([account_host, endpoint_host, "localhost"], "localhost", &valid_url_host?/1)
  end

  defp valid_url_host?(host) when is_binary(host) do
    Regex.match?(~r/^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?$/i, host)
  end

  defp valid_url_host?(_host), do: false

  defp normalize_url_scheme(scheme) when scheme in [:https, "https"], do: "https"
  defp normalize_url_scheme(_scheme), do: "http"

  defp listener_port(endpoint_config, "https") do
    endpoint_config |> Keyword.get(:https, []) |> Keyword.get(:port)
  end

  defp listener_port(endpoint_config, _scheme) do
    endpoint_config |> Keyword.get(:http, []) |> Keyword.get(:port)
  end

  defp normalize_url_port(port, scheme) when is_binary(port) do
    case Integer.parse(port) do
      {parsed, ""} -> normalize_url_port(parsed, scheme)
      _invalid -> nil
    end
  end

  defp normalize_url_port(443, "https"), do: nil
  defp normalize_url_port(80, "http"), do: nil
  defp normalize_url_port(port, _scheme) when is_integer(port) and port > 0, do: port
  defp normalize_url_port(_port, _scheme), do: nil

  defp mutate_and_reload(socket, result, success_message, action) do
    case result do
      :ok ->
        {:noreply, socket |> put_flash(:info, success_message) |> load_data()}

      result when is_tuple(result) and elem(result, 0) == :ok ->
        {:noreply, socket |> put_flash(:info, success_message) |> load_data()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, context_error_message(reason, action))}

      _other ->
        {:noreply, put_flash(socket, :error, "Steward could not #{action}. Please try again.")}
    end
  end

  defp invitation_mutation_error(socket, attrs, %Ecto.Changeset{} = changeset) do
    errors = changeset_errors(changeset) |> Map.take([:email, :role])

    if map_size(errors) > 0 do
      {:noreply, assign_invitation_form(socket, attrs, errors)}
    else
      {:noreply,
       put_flash(socket, :error, context_error_message(changeset, "create the invitation"))}
    end
  end

  defp invitation_mutation_error(socket, _attrs, reason) do
    {:noreply, put_flash(socket, :error, context_error_message(reason, "create the invitation"))}
  end

  defp context_error_message(reason, action) do
    case reason_code(reason) do
      :unauthorized -> "Your current role is not allowed to #{action}."
      :forbidden -> "Your current role is not allowed to #{action}."
      :not_found -> "The requested member or invitation no longer exists."
      :already_invited -> "A pending invitation already exists for that email address."
      :already_member -> "That account already belongs to this organization."
      :rate_limited -> "Invitation activity is temporarily limited. Please try again later."
      :invalid_role -> "That role cannot be assigned by your current account."
      :self_role_change -> "You cannot change your own organization role."
      :self_removal -> "You cannot remove your own account from this screen."
      :last_owner -> "The last owner cannot be demoted or removed. Assign another owner first."
      :protected_role -> "Your current role cannot modify that owner or administrator."
      :email_unverified -> "The target account must have a verified email address."
      _unknown -> "Steward could not #{action}. Please review the request and try again."
    end
  end

  defp reason_code(%Ecto.Changeset{}), do: :validation
  defp reason_code(reason) when is_atom(reason), do: normalize_reason_code(reason)
  defp reason_code({reason, _detail}) when is_atom(reason), do: normalize_reason_code(reason)
  defp reason_code(%{reason: reason}), do: reason_code(reason)
  defp reason_code(%{"reason" => reason}), do: reason_code(reason)

  defp reason_code(reason) when is_binary(reason) do
    normalized = String.downcase(reason)

    cond do
      String.contains?(normalized, "last owner") ->
        :last_owner

      String.contains?(normalized, "already") and String.contains?(normalized, "invite") ->
        :already_invited

      String.contains?(normalized, "already") and String.contains?(normalized, "member") ->
        :already_member

      String.contains?(normalized, "rate") and String.contains?(normalized, "limit") ->
        :rate_limited

      String.contains?(normalized, "own role") ->
        :self_role_change

      String.contains?(normalized, "own account") ->
        :self_removal

      String.contains?(normalized, "unauthor") ->
        :unauthorized

      String.contains?(normalized, "forbid") ->
        :forbidden

      String.contains?(normalized, "not found") ->
        :not_found

      String.contains?(normalized, "role") ->
        :invalid_role

      true ->
        :unknown
    end
  end

  defp reason_code(_reason), do: :unknown

  defp normalize_reason_code(reason) do
    case reason do
      reason when reason in [:unauthorized, :not_authorized] ->
        :unauthorized

      :forbidden ->
        :forbidden

      reason when reason in [:not_found, :member_not_found, :invitation_not_found] ->
        :not_found

      reason
      when reason in [:already_invited, :pending_invitation_exists, :duplicate_invitation] ->
        :already_invited

      reason when reason in [:already_member, :already_in_organization] ->
        :already_member

      reason when reason in [:rate_limited, :too_many_requests] ->
        :rate_limited

      reason when reason in [:invalid_role, :role_not_allowed] ->
        :invalid_role

      reason when reason in [:self_role_change, :cannot_change_own_role] ->
        :self_role_change

      reason when reason in [:self_removal, :cannot_remove_self] ->
        :self_removal

      reason when reason in [:last_owner, :cannot_remove_last_owner] ->
        :last_owner

      reason when reason in [:protected_role, :cannot_modify_owner, :cannot_modify_admin] ->
        :protected_role

      :email_unverified ->
        :email_unverified

      _reason ->
        :unknown
    end
  end

  defp normalize_invitation_attrs(params) do
    params = Map.new(params, fn {key, value} -> {to_string(key), value} end)

    %{
      email: params |> Map.get("email", "") |> String.trim() |> String.downcase(),
      role: params |> Map.get("role", "member") |> String.trim() |> String.downcase()
    }
  end

  defp validate_invitation(attrs, allowed_roles) do
    %{}
    |> validate_email(attrs.email)
    |> validate_invitation_role(attrs.role, allowed_roles)
  end

  defp validate_email(errors, ""), do: add_error(errors, :email, "Enter an email address.")

  defp validate_email(errors, email) do
    cond do
      String.length(email) > 160 ->
        add_error(errors, :email, "Use 160 characters or fewer.")

      not Regex.match?(@email_regex, email) ->
        add_error(errors, :email, "Enter a valid email address.")

      true ->
        errors
    end
  end

  defp validate_invitation_role(errors, role, allowed_roles) do
    if role in allowed_roles do
      errors
    else
      add_error(errors, :role, "Your account cannot invite this role.")
    end
  end

  defp add_error(errors, field_name, message) do
    Map.update(errors, field_name, [message], &[message | &1])
  end

  defp assign_invitation_form(socket, attrs, errors) do
    params = %{"email" => attrs.email, "role" => attrs.role}

    assign(socket,
      invitation_attrs: attrs,
      invitation_form: to_form(params, as: :invitation),
      invitation_errors: errors
    )
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
      Enum.reduce(options, message, fn {key, value}, rendered ->
        String.replace(rendered, "%{#{key}}", to_string(value))
      end)
    end)
  end

  defp allowed_invite_roles(%{assigns: %{current_role: "owner"}}), do: @roles
  defp allowed_invite_roles(%{current_role: "owner"}), do: @roles
  defp allowed_invite_roles(_socket_or_assigns), do: ["member"]

  defp role_options, do: @roles

  defp current_user_role(current_user, members) do
    current_id = field(current_user, :id)
    current_email = normalize_email(field(current_user, :email, ""))

    membership =
      Enum.find(members, fn member ->
        ids_match?(member_id(member), current_id) or
          normalize_email(member_email(member)) == current_email
      end)

    member_role(membership) || field(current_user, :org_role) || field(current_user, :role) ||
      "admin"
  end

  defp resolve_member_id(members, id) do
    case Enum.find(members, &(to_string(member_id(&1)) == to_string(id))) do
      nil -> nil
      member -> member_id(member)
    end
  end

  defp resolve_invitation_id(invitations, id) do
    case Enum.find(invitations, &(to_string(invitation_id(&1)) == to_string(id))) do
      nil -> nil
      invitation -> invitation_id(invitation)
    end
  end

  defp member_id(member) do
    user = field(member, :user)
    field(user, :id) || field(member, :user_id) || field(member, :id)
  end

  defp member_email(member) do
    user = field(member, :user)
    field(user, :email) || field(member, :email, "Unknown email")
  end

  defp member_name(member) do
    user = field(member, :user)
    name = field(user, :name) || field(member, :name)

    if is_binary(name) and String.trim(name) != "" do
      name
    else
      member_email(member) |> String.split("@") |> List.first()
    end
  end

  defp member_role(nil), do: nil

  defp member_role(member) do
    user = field(member, :user)
    field(member, :role) || field(member, :org_role) || field(user, :org_role) || "member"
  end

  defp member_joined_at(member) do
    field(member, :joined_at) || field(member, :inserted_at)
  end

  defp invitation_id(invitation), do: field(invitation, :id)
  defp invitation_email(invitation), do: field(invitation, :email, "Unknown email")
  defp invitation_role(invitation), do: field(invitation, :role, "member")

  defp invitation_link_state(invitation) do
    if field(invitation, :sent_at), do: "Ready to share", else: "Link pending"
  end

  defp can_manage_invitation?(_invitation, "owner"), do: true

  defp can_manage_invitation?(invitation, "admin") do
    invitation_role(invitation) == "member"
  end

  defp can_manage_invitation?(_invitation, _current_role), do: false

  defp current_member?(member, current_user),
    do: ids_match?(member_id(member), field(current_user, :id))

  defp can_edit_role?(member, current_user, "owner"),
    do: not current_member?(member, current_user)

  defp can_edit_role?(_member, _current_user, _current_role), do: false

  defp can_remove_member?(member, current_user, "owner"),
    do: not current_member?(member, current_user)

  defp can_remove_member?(member, current_user, "admin") do
    not current_member?(member, current_user) and member_role(member) == "member"
  end

  defp can_remove_member?(_member, _current_user, _current_role), do: false

  defp ids_match?(nil, _right), do: false
  defp ids_match?(_left, nil), do: false
  defp ids_match?(left, right), do: to_string(left) == to_string(right)

  defp dom_id(prefix, id) do
    safe_id = id |> to_string() |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
    "#{prefix}-#{safe_id}"
  end

  defp member_initial(member) do
    member
    |> member_name()
    |> String.trim()
    |> String.first()
    |> case do
      nil -> "?"
      initial -> String.upcase(initial)
    end
  end

  defp organization_name(organization),
    do: field(organization, :name, field(organization, :slug, "Organization"))

  defp organization_slug(organization), do: field(organization, :slug, "")

  defp format_datetime(nil), do: "—"
  defp format_datetime(%DateTime{} = datetime), do: Calendar.strftime(datetime, "%b %-d, %Y")
  defp format_datetime(%NaiveDateTime{} = datetime), do: Calendar.strftime(datetime, "%b %-d, %Y")
  defp format_datetime(value) when is_binary(value), do: value
  defp format_datetime(_value), do: "—"

  defp normalize_email(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_email(_value), do: ""

  defp empty_invitation_attrs, do: %{email: "", role: "member"}

  defp field(record, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(record, key, default) when is_map(record) do
    Map.get(record, key, Map.get(record, Atom.to_string(key), default))
  end

  defp field(_record, _key, default), do: default

  @impl true
  def render(assigns) do
    ~H"""
    <section id="members-live" class="account-shell members-shell">
      <div class="members-heading animate-in">
        <div class="account-intro">
          <p class="account-kicker"><span>Access control</span> / <%= organization_slug(@organization) %></p>
          <h1>Members & invitations</h1>
          <p>
            Keep <strong><%= organization_name(@organization) %></strong> deliberately small. Roles here define who can operate, administer, and own this Steward boundary.
          </p>
        </div>

        <div class="access-summary" aria-label="Organization access summary">
          <div><strong><%= length(@members) %></strong><span>Active</span></div>
          <div><strong><%= length(@pending_invitations) %></strong><span>Pending</span></div>
          <div><strong><%= @current_role %></strong><span>Your role</span></div>
        </div>
      </div>

      <div class="management-grid animate-in delay-1">
        <article class="card account-card invite-panel">
          <div class="account-card-heading">
            <div>
              <p class="account-kicker">Invite access</p>
              <h2>Create an access link</h2>
            </div>
            <span class="coordinate-mark" aria-hidden="true">ACL / NEW</span>
          </div>

          <.form for={@invitation_form} id="invite-form" phx-change="validate-invitation" phx-submit="invite-member" novalidate>
            <div class="form-stack compact">
              <div class="form-field">
                <label for="invite-email" class="form-label">Email address</label>
                <input
                  id="invite-email"
                  name={@invitation_form[:email].name}
                  value={@invitation_form[:email].value}
                  type="email"
                  class="form-control"
                  autocomplete="email"
                  maxlength="160"
                  placeholder="teammate@example.com"
                  aria-invalid={Map.has_key?(@invitation_errors, :email)}
                  aria-describedby="invite-email-hint invite-email-errors"
                />
                <p id="invite-email-hint" class="form-hint">The invited user must sign in with this exact email.</p>
                <div id="invite-email-errors" class="field-errors" aria-live="polite">
                  <%= for message <- Map.get(@invitation_errors, :email, []) do %>
                    <p><%= message %></p>
                  <% end %>
                </div>
              </div>

              <div class="form-field">
                <label for="invite-role" class="form-label">Organization role</label>
                <select
                  id="invite-role"
                  name={@invitation_form[:role].name}
                  class="form-control form-select"
                  aria-invalid={Map.has_key?(@invitation_errors, :role)}
                  aria-describedby="invite-role-hint invite-role-errors"
                >
                  <%= for role <- allowed_invite_roles(assigns) do %>
                    <option value={role} selected={@invitation_form[:role].value == role}><%= role %></option>
                  <% end %>
                </select>
                <p id="invite-role-hint" class="form-hint">
                  <%= if @current_role == "owner", do: "Owners can invite any role.", else: "Administrators can invite members." %>
                </p>
                <div id="invite-role-errors" class="field-errors" aria-live="polite">
                  <%= for message <- Map.get(@invitation_errors, :role, []) do %>
                    <p><%= message %></p>
                  <% end %>
                </div>
              </div>
            </div>

            <p class="invite-delivery-note">
              Email delivery is not configured. Steward will reveal a private URL for you to copy and share.
            </p>
            <button id="invite-submit" type="submit" class="btn btn-primary btn-block" phx-disable-with="Creating link…">
              Create invitation link <span aria-hidden="true">→</span>
            </button>
          </.form>

          <%= if @invitation_link do %>
            <aside id="invitation-link-reveal" class="invitation-link-reveal" role="status" aria-live="polite">
              <div class="invitation-link-heading">
                <div>
                  <p class="account-kicker">One-time link</p>
                  <h3>Copy before you leave</h3>
                </div>
                <span class="link-ready-mark" aria-hidden="true">Ready</span>
              </div>
              <p id="invitation-link-recipient">
                Share only with <strong><%= @invitation_link.email %></strong>. Creating another link invalidates this one.
              </p>
              <label for="invitation-url" class="form-label">Invitation URL</label>
              <div class="copy-field">
                <input
                  id="invitation-url"
                  type="url"
                  value={@invitation_link.url}
                  class="form-control mono"
                  readonly
                  spellcheck="false"
                  aria-describedby="invitation-copy-status invitation-link-expiry"
                />
                <button
                  id="copy-invitation-url"
                  type="button"
                  class="btn btn-copy"
                  data-copy-target="invitation-url"
                  data-copy-status="invitation-copy-status"
                  data-copy-label="Copy URL"
                >
                  Copy URL
                </button>
              </div>
              <p id="invitation-copy-status" class="form-hint" aria-live="polite">
                This secret URL is available only in this live session.
              </p>
              <p id="invitation-link-expiry" class="link-expiry">
                Expires <%= format_datetime(@invitation_link.expires_at) %>
              </p>
            </aside>
          <% end %>
        </article>

        <aside class="card account-card role-guide" aria-labelledby="role-guide-title">
          <p class="account-kicker">Permission map</p>
          <h2 id="role-guide-title">Three levels, one boundary</h2>
          <dl>
            <div>
              <dt><span class="role-badge role-member">member</span></dt>
              <dd>Uses Steward's operational workspace.</dd>
            </div>
            <div>
              <dt><span class="role-badge role-admin">admin</span></dt>
              <dd>Manages members and member invitations.</dd>
            </div>
            <div>
              <dt><span class="role-badge role-owner">owner</span></dt>
              <dd>Controls roles, ownership, and all access.</dd>
            </div>
          </dl>
          <p class="form-hint">Every mutation is re-authorized against your current server-side role.</p>
        </aside>
      </div>

      <article class="card management-card animate-in delay-2" aria-labelledby="members-title">
        <div class="management-card-header">
          <div>
            <p class="account-kicker">Current access</p>
            <h2 id="members-title">Organization members</h2>
          </div>
          <span class="section-count"><%= length(@members) %> total</span>
        </div>

        <%= if Enum.empty?(@members) do %>
          <div id="members-empty" class="empty-state">
            <div class="empty-state-icon" aria-hidden="true">◇</div>
            <p class="empty-state-title">No members found</p>
            <p class="empty-state-desc">Members will appear here after they join this organization.</p>
          </div>
        <% else %>
          <div class="table-scroll">
            <table id="members-table" class="requests-table management-table">
              <caption class="sr-only">Members of <%= organization_name(@organization) %></caption>
              <thead>
                <tr>
                  <th scope="col">Member</th>
                  <th scope="col">Role</th>
                  <th scope="col">Joined</th>
                  <th scope="col" class="actions-column">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for member <- @members do %>
                  <tr id={dom_id("member-row", member_id(member))}>
                    <td>
                      <div class="member-identity">
                        <span class="member-avatar" aria-hidden="true"><%= member_initial(member) %></span>
                        <span>
                          <strong><%= member_name(member) %></strong>
                          <small><%= member_email(member) %></small>
                        </span>
                        <%= if current_member?(member, @current_user) do %>
                          <span class="you-badge">You</span>
                        <% end %>
                      </div>
                    </td>
                    <td><span class={"role-badge role-#{member_role(member)}"}><%= member_role(member) %></span></td>
                    <td class="timestamp"><%= format_datetime(member_joined_at(member)) %></td>
                    <td>
                      <div class="table-actions">
                        <%= if can_edit_role?(member, @current_user, @current_role) do %>
                          <form id={dom_id("role-form", member_id(member))} phx-submit="change-role" class="role-form">
                            <input type="hidden" name="target_id" value={member_id(member)} />
                            <label class="sr-only" for={dom_id("member-role", member_id(member))}>Role for <%= member_email(member) %></label>
                            <select id={dom_id("member-role", member_id(member))} name="role" class="form-control form-select form-control-sm">
                              <%= for role <- role_options() do %>
                                <option value={role} selected={member_role(member) == role}><%= role %></option>
                              <% end %>
                            </select>
                            <button
                              type="submit"
                              class="btn btn-ghost btn-sm"
                              data-confirm={"Change #{member_email(member)} to the selected role?"}
                            >
                              Save
                            </button>
                          </form>
                        <% end %>

                        <%= if can_remove_member?(member, @current_user, @current_role) do %>
                          <button
                            id={dom_id("remove-member", member_id(member))}
                            type="button"
                            phx-click="remove-member"
                            phx-value-id={member_id(member)}
                            class="btn btn-danger btn-sm"
                            data-confirm={"Remove #{member_email(member)} from #{organization_name(@organization)}? Their active sessions will end."}
                          >
                            Remove
                          </button>
                        <% end %>

                        <%= if not can_edit_role?(member, @current_user, @current_role) and not can_remove_member?(member, @current_user, @current_role) do %>
                          <span class="table-muted"><%= if current_member?(member, @current_user), do: "Current account", else: "Protected" %></span>
                        <% end %>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </article>

      <article class="card management-card animate-in delay-2" aria-labelledby="pending-invitations-title">
        <div class="management-card-header">
          <div>
            <p class="account-kicker">Awaiting response</p>
            <h2 id="pending-invitations-title">Pending invitations</h2>
          </div>
          <span class="section-count"><%= length(@pending_invitations) %> open</span>
        </div>

        <%= if Enum.empty?(@pending_invitations) do %>
          <div id="pending-invitations-empty" class="empty-state compact-empty">
            <div class="empty-state-icon" aria-hidden="true">✓</div>
            <p class="empty-state-title">No pending invitations</p>
            <p class="empty-state-desc">Every invitation has been accepted, revoked, or expired.</p>
          </div>
        <% else %>
          <div class="table-scroll">
            <table id="pending-invitations-table" class="requests-table management-table">
              <caption class="sr-only">Pending invitations for <%= organization_name(@organization) %></caption>
              <thead>
                <tr>
                  <th scope="col">Invited email</th>
                  <th scope="col">Role</th>
                  <th scope="col">Link status</th>
                  <th scope="col">Expires</th>
                  <th scope="col" class="actions-column">Actions</th>
                </tr>
              </thead>
              <tbody>
                <%= for invitation <- @pending_invitations do %>
                  <tr id={dom_id("invitation-row", invitation_id(invitation))}>
                    <td><strong class="table-primary"><%= invitation_email(invitation) %></strong></td>
                    <td><span class={"role-badge role-#{invitation_role(invitation)}"}><%= invitation_role(invitation) %></span></td>
                    <td>
                      <span class="delivery-state"><span class="status-dot" aria-hidden="true"></span><%= invitation_link_state(invitation) %></span>
                    </td>
                    <td class="timestamp"><%= format_datetime(field(invitation, :expires_at)) %></td>
                    <td>
                      <div class="table-actions">
                        <%= if can_manage_invitation?(invitation, @current_role) do %>
                          <button
                            id={dom_id("resend-invitation", invitation_id(invitation))}
                            type="button"
                            phx-click="resend-invitation"
                            phx-value-id={invitation_id(invitation)}
                            class="btn btn-ghost btn-sm"
                            data-confirm={"Create a new link for #{invitation_email(invitation)}? Their current link will stop working."}
                          >
                            New link
                          </button>
                          <button
                            id={dom_id("revoke-invitation", invitation_id(invitation))}
                            type="button"
                            phx-click="revoke-invitation"
                            phx-value-id={invitation_id(invitation)}
                            class="btn btn-danger btn-sm"
                            data-confirm={"Revoke the invitation for #{invitation_email(invitation)}? Their current link will stop working."}
                          >
                            Revoke
                          </button>
                        <% else %>
                          <span class="table-muted">Protected</span>
                        <% end %>
                      </div>
                    </td>
                  </tr>
                <% end %>
              </tbody>
            </table>
          </div>
        <% end %>
      </article>
    </section>
    """
  end
end
