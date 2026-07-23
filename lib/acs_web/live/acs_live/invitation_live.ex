defmodule AcsWeb.AcsLive.InvitationLive do
  @moduledoc """
  Account-host LiveView for inspecting and accepting an organization invitation.

  Loading the page is read-only. Acceptance only happens through a LiveView event.
  """

  use AcsWeb, :live_view

  alias Acs.{Accounts, Orgs}

  def on_mount(_params, _session, socket) do
    {:cont, assign(socket, current_path: socket.assigns[:current_path] || "/")}
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       account_host: true,
       invite_token: nil,
       invitation: nil,
       invitation_state: :loading,
       acceptance_error: nil,
       accepted: false,
       can_continue: false,
       organization: current_organization(socket.assigns[:current_user])
     )}
  end

  @impl true
  def handle_params(params, url, socket) do
    path = url |> URI.parse() |> Map.get(:path, "/")
    token = Map.get(params, "token")

    socket =
      socket
      |> assign(current_path: path, invite_token: token, acceptance_error: nil)
      |> load_invitation()

    {:noreply, socket}
  end

  @impl true
  def handle_event("accept-invitation", _params, socket) do
    socket = refresh_account_context(socket)

    cond do
      not is_binary(socket.assigns.invite_token) or socket.assigns.invite_token == "" ->
        {:noreply, put_flash(socket, :error, "This invitation link is not valid.")}

      is_nil(socket.assigns.invitation) ->
        {:noreply, put_flash(socket, :error, "This invitation is no longer available.")}

      socket.assigns.invitation_state != :pending ->
        {:noreply,
         put_flash(socket, :error, unavailable_message(socket.assigns.invitation_state))}

      email_mismatch?(socket.assigns.invitation, socket.assigns.current_user) ->
        message = mismatch_message(socket.assigns.invitation)

        {:noreply,
         socket
         |> assign(acceptance_error: message)
         |> put_flash(:error, message)}

      true ->
        accept_invitation(socket)
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_invitation(socket)}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp accept_invitation(socket) do
    case Accounts.accept_invitation(socket.assigns.current_user, socket.assigns.invite_token) do
      {:ok, current_user, invitation} ->
        {:noreply, assign_accepted_invitation(socket, current_user, invitation)}

      # Keep compatibility with an older context shape while always reloading the account.
      {:ok, _result} ->
        {:noreply,
         socket
         |> refresh_account_context()
         |> assign_accepted_invitation(socket.assigns.invitation)}

      :ok ->
        {:noreply,
         socket
         |> refresh_account_context()
         |> assign_accepted_invitation(socket.assigns.invitation)}

      {:error, reason} ->
        kind = invitation_error_kind(reason)
        message = invitation_error_message(kind)
        socket = refresh_account_context(socket)

        {:noreply,
         socket
         |> assign(
           invitation_state: error_state(kind, socket.assigns.invitation_state),
           acceptance_error: message,
           can_continue: kind == :already_accepted and not is_nil(socket.assigns.organization)
         )
         |> put_flash(:error, message)}

      _other ->
        message = invitation_error_message(:unknown)
        {:noreply, socket |> assign(acceptance_error: message) |> put_flash(:error, message)}
    end
  end

  defp assign_accepted_invitation(socket, current_user, invitation) do
    invitation = hydrate_invitation(invitation)

    organization =
      current_organization(current_user) || invitation_organization_record(invitation)

    socket
    |> assign(
      current_user: current_user,
      invitation: invitation,
      invitation_state: :accepted,
      acceptance_error: nil,
      accepted: true,
      can_continue: not is_nil(organization),
      organization: organization
    )
    |> put_flash(:info, "Invitation accepted. Your Steward workspace is ready to continue.")
  end

  defp assign_accepted_invitation(socket, invitation) do
    assign_accepted_invitation(socket, socket.assigns.current_user, invitation)
  end

  defp load_invitation(%{assigns: %{invite_token: token}} = socket)
       when is_binary(token) and token != "" do
    socket = refresh_account_context(socket)
    organization = socket.assigns.organization

    case Accounts.get_invitation_by_token(token) do
      {:ok, invitation} ->
        assign_loaded_invitation(socket, invitation, organization)

      {:error, reason} ->
        kind = invitation_error_kind(reason)

        assign(socket,
          invitation: nil,
          invitation_state: lookup_state(kind),
          acceptance_error: nil,
          accepted: false,
          can_continue: false,
          organization: organization
        )

      nil ->
        assign(socket,
          invitation: nil,
          invitation_state: :invalid,
          acceptance_error: nil,
          accepted: false,
          can_continue: false,
          organization: organization
        )

      invitation ->
        assign_loaded_invitation(socket, invitation, organization)
    end
  end

  defp load_invitation(socket) do
    assign(socket,
      invitation: nil,
      invitation_state: :invalid,
      acceptance_error: nil,
      accepted: false,
      can_continue: false
    )
  end

  defp assign_loaded_invitation(socket, invitation, organization) do
    invitation = hydrate_invitation(invitation)
    state = invitation_state(invitation)
    matching_user = not email_mismatch?(invitation, socket.assigns.current_user)
    can_continue = state == :accepted and matching_user and not is_nil(organization)

    assign(socket,
      invitation: invitation,
      invitation_state: state,
      acceptance_error: nil,
      accepted: false,
      can_continue: can_continue,
      organization: organization
    )
  end

  defp invitation_state(invitation) do
    status = invitation |> field(:status, "") |> to_string() |> String.downcase()

    cond do
      present?(field(invitation, :revoked_at)) -> :revoked
      present?(field(invitation, :accepted_at)) -> :accepted
      expired?(field(invitation, :expires_at)) -> :expired
      status in ["revoked", "cancelled", "canceled"] -> :revoked
      status in ["accepted", "used"] -> :accepted
      status in ["expired"] -> :expired
      true -> :pending
    end
  end

  defp expired?(%DateTime{} = expires_at),
    do: DateTime.compare(expires_at, DateTime.utc_now()) != :gt

  defp expired?(%NaiveDateTime{} = expires_at) do
    NaiveDateTime.compare(expires_at, DateTime.utc_now() |> DateTime.to_naive()) != :gt
  end

  defp expired?(_expires_at), do: false

  defp refresh_account_context(socket) do
    current_user = reload_current_user(socket.assigns[:current_user])
    assign(socket, current_user: current_user, organization: current_organization(current_user))
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

  defp hydrate_invitation(invitation) do
    case invitation_organization_record(invitation) do
      nil -> invitation
      organization -> Map.put(invitation, :organization, organization)
    end
  end

  defp invitation_organization_record(invitation) do
    case field(invitation, :organization) do
      organization when is_map(organization) ->
        if organization_record?(organization) do
          organization
        else
          find_invitation_organization(field(invitation, :organization_id))
        end

      _organization ->
        find_invitation_organization(field(invitation, :organization_id))
    end
  end

  defp organization_record?(organization) do
    present?(field(organization, :name)) or present?(field(organization, :slug)) or
      present?(field(organization, :subdomain))
  end

  defp find_invitation_organization(nil), do: nil

  defp find_invitation_organization(organization_id) do
    Enum.find(Orgs.list_all(), fn organization ->
      to_string(field(organization, :id)) == to_string(organization_id)
    end)
  end

  defp email_mismatch?(invitation, user) do
    invited_email = invitation_email(invitation) |> normalize_email()
    current_email = field(user, :email, "") |> normalize_email()
    invited_email != "" and current_email != "" and invited_email != current_email
  end

  defp mismatch_message(invitation) do
    "This invitation is for #{invitation_email(invitation)}. Sign in with that exact email address to accept it."
  end

  defp invitation_email(invitation),
    do: field(invitation, :email, field(invitation, :normalized_email, "Unknown"))

  defp invitation_role(invitation), do: field(invitation, :role, "member")

  defp invitation_organization(invitation) do
    organization = field(invitation, :organization)

    cond do
      is_map(organization) ->
        field(organization, :name, field(organization, :slug, "Unknown organization"))

      is_binary(organization) ->
        organization

      true ->
        field(
          invitation,
          :organization_name,
          field(
            invitation,
            :org_name,
            field(invitation, :organization_slug, "Unknown organization")
          )
        )
    end
  end

  defp invitation_slug(invitation) do
    organization = field(invitation, :organization)

    cond do
      is_map(organization) -> field(organization, :slug)
      true -> field(invitation, :organization_slug, field(invitation, :org))
    end
  end

  defp invitation_error_kind(reason) when is_atom(reason), do: normalize_error_atom(reason)

  defp invitation_error_kind({reason, _detail}) when is_atom(reason),
    do: normalize_error_atom(reason)

  defp invitation_error_kind(%{reason: reason}), do: invitation_error_kind(reason)
  defp invitation_error_kind(%{"reason" => reason}), do: invitation_error_kind(reason)

  defp invitation_error_kind(reason) when is_binary(reason) do
    normalized = String.downcase(reason)

    cond do
      String.contains?(normalized, "expir") ->
        :expired

      String.contains?(normalized, "revok") ->
        :revoked

      String.contains?(normalized, "email") and String.contains?(normalized, "match") ->
        :mismatch

      String.contains?(normalized, "already") and String.contains?(normalized, "org") ->
        :already_org

      String.contains?(normalized, "already") and String.contains?(normalized, "accept") ->
        :already_accepted

      String.contains?(normalized, "not found") or String.contains?(normalized, "invalid") ->
        :invalid

      true ->
        :unknown
    end
  end

  defp invitation_error_kind(_reason), do: :unknown

  defp normalize_error_atom(reason) do
    case reason do
      reason when reason in [:expired, :invitation_expired] ->
        :expired

      reason when reason in [:revoked, :invitation_revoked] ->
        :revoked

      reason when reason in [:email_mismatch, :invitation_email_mismatch, :mismatched_email] ->
        :mismatch

      reason
      when reason in [:already_in_organization, :already_has_organization, :already_member] ->
        :already_org

      reason when reason in [:already_accepted, :invitation_accepted, :used] ->
        :already_accepted

      reason when reason in [:invalid, :invalid_token, :not_found, :invitation_not_found] ->
        :invalid

      _reason ->
        :unknown
    end
  end

  defp invitation_error_message(:expired),
    do: "This invitation has expired. Ask an organization administrator to send a new one."

  defp invitation_error_message(:revoked),
    do:
      "This invitation was revoked. Contact the organization administrator if you still need access."

  defp invitation_error_message(:mismatch),
    do: "The signed-in email does not match this invitation. Use the invited email address."

  defp invitation_error_message(:already_org),
    do: "Your account already belongs to an organization and cannot accept another invitation."

  defp invitation_error_message(:already_accepted),
    do: "This invitation has already been accepted."

  defp invitation_error_message(:invalid),
    do: "This invitation link is invalid or no longer available."

  defp invitation_error_message(:unknown),
    do:
      "Steward could not accept this invitation. Ask the organization administrator for a new link."

  defp error_state(kind, _current) when kind in [:expired, :revoked], do: kind
  defp error_state(:already_accepted, _current), do: :accepted
  defp error_state(_kind, current), do: current

  defp lookup_state(kind) when kind in [:expired, :revoked], do: kind
  defp lookup_state(_kind), do: :invalid

  defp unavailable_message(:expired), do: invitation_error_message(:expired)
  defp unavailable_message(:revoked), do: invitation_error_message(:revoked)
  defp unavailable_message(:accepted), do: invitation_error_message(:already_accepted)
  defp unavailable_message(_state), do: invitation_error_message(:invalid)

  defp status_label(:pending), do: "Pending acceptance"
  defp status_label(:accepted), do: "Accepted"
  defp status_label(:expired), do: "Expired"
  defp status_label(:revoked), do: "Revoked"
  defp status_label(:invalid), do: "Unavailable"
  defp status_label(:loading), do: "Checking"

  defp format_datetime(nil), do: "Not specified"

  defp format_datetime(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%b %-d, %Y at %-I:%M %p UTC")

  defp format_datetime(%NaiveDateTime{} = datetime),
    do: Calendar.strftime(datetime, "%b %-d, %Y at %-I:%M %p UTC")

  defp format_datetime(value) when is_binary(value), do: value
  defp format_datetime(_value), do: "Not specified"

  defp normalize_email(value) when is_binary(value),
    do: value |> String.trim() |> String.downcase()

  defp normalize_email(_value), do: ""

  defp present?(value), do: not is_nil(value) and value != ""

  defp field(record, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(record, key, default) when is_map(record) do
    Map.get(record, key, Map.get(record, Atom.to_string(key), default))
  end

  defp field(_record, _key, default), do: default

  @impl true
  def render(assigns) do
    ~H"""
    <section id="invitation-live" class="account-shell account-shell-narrow">
      <div class="account-intro animate-in">
        <p class="account-kicker"><span>Access handoff</span> / Organization invitation</p>
        <h1>Confirm the boundary before you enter.</h1>
        <p>
          Review who invited you, where you are joining, and the exact access role. Nothing changes until you accept.
        </p>
      </div>

      <article class="card account-card invitation-card animate-in delay-1">
        <%= if @invitation do %>
          <div class="account-card-heading">
            <div>
              <p class="account-kicker">Invitation details</p>
              <h2><%= invitation_organization(@invitation) %></h2>
              <%= if slug = invitation_slug(@invitation) do %>
                <code class="organization-slug"><%= slug %></code>
              <% end %>
            </div>
            <span id="invitation-status" class={"status-chip status-#{@invitation_state}"}>
              <span class="status-dot" aria-hidden="true"></span>
              <%= status_label(@invitation_state) %>
            </span>
          </div>

          <dl class="invitation-details" id="invitation-details">
            <div>
              <dt>Invited email</dt>
              <dd id="invitation-email"><%= invitation_email(@invitation) %></dd>
            </div>
            <div>
              <dt>Organization</dt>
              <dd id="invitation-organization"><%= invitation_organization(@invitation) %></dd>
            </div>
            <div>
              <dt>Assigned role</dt>
              <dd id="invitation-role"><span class={"role-badge role-#{invitation_role(@invitation)}"}><%= invitation_role(@invitation) %></span></dd>
            </div>
            <div>
              <dt>Valid until</dt>
              <dd id="invitation-expires-at"><%= format_datetime(field(@invitation, :expires_at)) %></dd>
            </div>
          </dl>

          <div class="invitation-decision" aria-live="polite">
            <%= cond do %>
              <% @accepted or @can_continue -> %>
                <div id="invitation-accepted" class="decision-copy decision-success">
                  <span class="decision-icon" aria-hidden="true">✓</span>
                  <div>
                    <h3>Access confirmed</h3>
                    <p>Your account is assigned to this organization. Continue to its Steward workspace.</p>
                  </div>
                </div>
                <.link id="invitation-continue" href="/auth/log_in" class="btn btn-primary">
                  Open workspace <span aria-hidden="true">→</span>
                </.link>

              <% @invitation_state == :pending and email_mismatch?(@invitation, @current_user) -> %>
                <div id="invitation-email-mismatch" class="decision-copy decision-warning">
                  <span class="decision-icon" aria-hidden="true">!</span>
                  <div>
                    <h3>Use the invited account</h3>
                    <p>
                      You are signed in as <strong><%= @current_user.email %></strong>. This invitation can only be accepted by
                      <strong><%= invitation_email(@invitation) %></strong>.
                    </p>
                  </div>
                </div>

              <% @invitation_state == :pending -> %>
                <div class="decision-copy">
                  <span class="decision-icon" aria-hidden="true">→</span>
                  <div>
                    <h3>Ready for acceptance</h3>
                    <p>Accepting assigns this account to the organization and role shown above.</p>
                  </div>
                </div>
                <button
                  id="accept-invitation"
                  type="button"
                  phx-click="accept-invitation"
                  phx-disable-with="Accepting invitation…"
                  class="btn btn-primary"
                >
                  Accept invitation
                </button>

              <% @invitation_state == :expired -> %>
                <div id="invitation-expired" class="decision-copy decision-warning">
                  <span class="decision-icon" aria-hidden="true">⌁</span>
                  <div>
                    <h3>This invitation expired</h3>
                    <p>Ask an organization administrator to send a fresh invitation.</p>
                  </div>
                </div>

              <% @invitation_state == :revoked -> %>
                <div id="invitation-revoked" class="decision-copy decision-danger">
                  <span class="decision-icon" aria-hidden="true">×</span>
                  <div>
                    <h3>This invitation was revoked</h3>
                    <p>Contact the organization administrator if you still need access.</p>
                  </div>
                </div>

              <% true -> %>
                <div class="decision-copy decision-warning">
                  <span class="decision-icon" aria-hidden="true">◇</span>
                  <div>
                    <h3>This invitation is unavailable</h3>
                    <p>Ask the organization administrator to send a new invitation.</p>
                  </div>
                </div>
            <% end %>

            <%= if @acceptance_error do %>
              <p id="invitation-acceptance-error" class="field-errors"><%= @acceptance_error %></p>
            <% end %>
          </div>
        <% else %>
          <div id="invitation-unavailable" class="empty-state invitation-empty" aria-live="polite">
            <div class="empty-state-icon" aria-hidden="true">◇</div>
            <p class="empty-state-title">
              <%= if @invitation_state == :loading, do: "Checking invitation", else: "Invitation unavailable" %>
            </p>
            <p class="empty-state-desc">
              <%= case @invitation_state do %>
                <% :expired -> %>This invitation has expired. Ask the organization administrator for a new link.
                <% :revoked -> %>This invitation has been revoked by the organization.
                <% :loading -> %>Steward is verifying this invitation.
                <% _invalid -> %>The link is invalid, has already been replaced, or is no longer available.
              <% end %>
            </p>
            <%= if @invitation_state != :loading do %>
              <button id="refresh-invitation" type="button" phx-click="refresh" class="btn btn-ghost">↻ Check again</button>
            <% end %>
          </div>
        <% end %>
      </article>

      <p class="account-footnote animate-in delay-2">
        Steward never accepts an invitation on page load. Your explicit confirmation is required.
      </p>
    </section>
    """
  end
end
