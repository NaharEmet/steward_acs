defmodule Acs.Accounts do
  @moduledoc """
  Accounts, organization membership, invitations, and session handoffs.
  """
  import Ecto.Query, warn: false

  alias Acs.Accounts.{AccountAuditEvent, OrganizationInvitation, SessionHandoff, User, UserToken}
  alias Acs.Orgs.Organization
  alias Acs.Repo

  @invitation_lifetime 7 * 24 * 60 * 60
  @handoff_lifetime 60
  @token_bytes 32

  def get_user!(id), do: Repo.get!(User, id)

  def get_user_by_email(email, org \\ Acs.Org.current()) when is_binary(email) do
    email = normalize_email(email)

    case organization_and_slug(org) do
      {organization_id, nil} when is_integer(organization_id) ->
        Repo.one(
          from user in User,
            where: user.normalized_email == ^email and user.organization_id == ^organization_id
        )

      {organization_id, slug} when is_integer(organization_id) and is_binary(slug) ->
        Repo.one(
          from user in User,
            where:
              user.normalized_email == ^email and
                (user.organization_id == ^organization_id or user.org == ^slug)
        )

      {nil, slug} when is_binary(slug) ->
        Repo.one(from user in User, where: user.normalized_email == ^email and user.org == ^slug)

      _ ->
        Repo.get_by(User, normalized_email: email)
    end
  end

  def get_user_by_oidc_identity(issuer, subject) when is_binary(issuer) and is_binary(subject) do
    Repo.get_by(User,
      oidc_issuer: normalize_issuer(issuer),
      oidc_subject: String.trim(subject)
    )
  end

  def register_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def get_or_register_user(email, org \\ Acs.Org.current()) do
    case get_user_by_email(email, org) do
      %User{} = user -> {:ok, user}
      nil -> register_user(%{email: email, org: org})
    end
  end

  def upsert_oidc_user(
        %{issuer: issuer, subject: subject, email: email, email_verified: true} = attrs
      )
      when is_binary(issuer) and is_binary(subject) and is_binary(email) do
    name = Map.get(attrs, :name)

    Repo.transaction(fn ->
      issuer = normalize_issuer(issuer)
      normalized_email = normalize_email(email)

      user =
        get_user_by_oidc_identity(issuer, subject) ||
          linkable_user_by_email(normalized_email) ||
          %User{}

      if is_nil(user.id) and oidc_email_claimed?(normalized_email) do
        Repo.rollback(:email_identity_conflict)
      end

      new_user? = is_nil(user.id)

      changes = %{
        email: email,
        name: name,
        oidc_issuer: issuer,
        oidc_subject: subject,
        confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      case user |> User.changeset(changes) |> Repo.insert_or_update() do
        {:ok, user} ->
          audit!(%{
            actor_id: user.id,
            target_user_id: user.id,
            organization_id: user.organization_id,
            event: if(new_user?, do: "user.oidc_created", else: "user.oidc_updated"),
            metadata: %{"issuer" => issuer}
          })

          user

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  def upsert_oidc_user(_), do: {:error, :email_not_verified}

  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  def get_user_by_session_token(token, org \\ nil) do
    case UserToken.verify_session_token_query(token, org) do
      {:ok, query} -> Repo.one(query)
      :error -> nil
    end
  end

  def delete_user_session_token(token) do
    case decode_token(token) do
      {:ok, decoded} ->
        Repo.delete_all(
          from token in UserToken,
            where: token.token == ^hash_token(decoded) and token.context == "session"
        )

        :ok

      :error ->
        :ok
    end
  end

  def delete_user_sessions(user_id), do: revoke_user_auth(user_id)

  def revoke_user_auth(user_id, opts \\ []) when is_integer(user_id) do
    current = now()

    Repo.delete_all(
      from token in UserToken, where: token.user_id == ^user_id and token.context == "session"
    )

    Repo.update_all(
      from(handoff in SessionHandoff,
        where: handoff.user_id == ^user_id and is_nil(handoff.consumed_at)
      ),
      set: [consumed_at: current, updated_at: current]
    )

    if Keyword.get(opts, :broadcast, true) do
      AcsWeb.Endpoint.broadcast("users:#{user_id}", "disconnect", %{})
    end

    :ok
  end

  def organization_for_user(%User{organization_id: organization_id})
      when is_integer(organization_id) do
    Repo.get(Organization, organization_id)
  end

  def organization_for_user(_), do: nil

  @doc "Assigns a verified OIDC user as owner during the basic-auth migration."
  def bootstrap_owner(email, organization_slug)
      when is_binary(email) and is_binary(organization_slug) do
    with %User{} = user <- Repo.get_by(User, normalized_email: normalize_email(email)),
         true <- is_binary(user.oidc_subject) and user.oidc_subject != "",
         %Organization{} = organization <-
           Repo.get_by(Organization, slug: String.downcase(organization_slug)),
         true <- is_nil(user.organization_id) or user.organization_id == organization.id do
      Repo.transaction(fn ->
        case user
             |> User.changeset(%{
               organization_id: organization.id,
               org_role: "owner",
               org: organization.slug
             })
             |> Repo.update() do
          {:ok, updated_user} ->
            revoke_user_auth(updated_user.id, broadcast: false)
            updated_user

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    else
      nil -> {:error, :not_found}
      false -> {:error, :invalid_user_or_membership}
      _ -> {:error, :invalid_user_or_membership}
    end
  end

  def list_members(organization_or_id) do
    case organization_id(organization_or_id) do
      nil ->
        []

      organization_id ->
        Repo.all(
          from user in User,
            where: user.organization_id == ^organization_id,
            order_by: [asc: user.email]
        )
    end
  end

  def list_pending_invitations(organization_or_id) do
    case organization_id(organization_or_id) do
      nil ->
        []

      organization_id ->
        now = now()

        Repo.all(
          from invitation in OrganizationInvitation,
            where:
              invitation.organization_id == ^organization_id and is_nil(invitation.accepted_at) and
                is_nil(invitation.revoked_at) and invitation.expires_at > ^now,
            order_by: [desc: invitation.inserted_at]
        )
    end
  end

  def invite_user(actor, attrs) do
    with {:ok, actor} <- admin_actor(actor),
         {:ok, email} <- invitation_email(attrs),
         {:ok, role} <- invitation_role(attrs),
         :ok <- can_assign_role(actor, role) do
      Repo.transaction(fn ->
        expire_invitations(actor.organization_id)

        case Repo.get_by(User, normalized_email: normalize_email(email)) do
          %User{organization_id: organization_id} when is_integer(organization_id) ->
            Repo.rollback(:already_in_organization)

          _ ->
            case pending_invitation(actor.organization_id, email) do
              nil -> create_invitation!(actor, email, role)
              _ -> Repo.rollback(:already_invited)
            end
        end
      end)
      |> invitation_result()
    end
  end

  def resend_invitation(actor, invitation_id) do
    with {:ok, actor} <- admin_actor(actor) do
      Repo.transaction(fn ->
        invitation = Repo.get(OrganizationInvitation, invitation_id)
        token = raw_token()
        current = now()

        with :ok <- manageable_invitation(actor, invitation),
             :ok <- active_invitation(invitation),
             {1, _} <-
               Repo.update_all(
                 from(candidate in OrganizationInvitation,
                   where:
                     candidate.id == ^invitation.id and
                       candidate.organization_id == ^actor.organization_id and
                       is_nil(candidate.accepted_at) and is_nil(candidate.revoked_at) and
                       candidate.expires_at > ^current
                 ),
                 set: [
                   token_hash: hash_token(token),
                   expires_at: DateTime.add(current, @invitation_lifetime, :second),
                   sent_at: current,
                   send_count: invitation.send_count + 1,
                   updated_at: current
                 ]
               ) do
          invitation = Repo.get!(OrganizationInvitation, invitation.id)

          audit!(%{
            actor_id: actor.id,
            organization_id: actor.organization_id,
            event: "invitation.resent",
            metadata: %{"invitation_id" => invitation.id}
          })

          {invitation, encode_token(token)}
        else
          {0, _} -> Repo.rollback(:invalid_invitation)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> invitation_result()
    end
  end

  def revoke_invitation(actor, invitation_id) do
    with {:ok, actor} <- admin_actor(actor) do
      Repo.transaction(fn ->
        invitation = Repo.get(OrganizationInvitation, invitation_id)
        current = now()

        with :ok <- manageable_invitation(actor, invitation),
             :ok <- active_invitation(invitation),
             {1, _} <-
               Repo.update_all(
                 from(candidate in OrganizationInvitation,
                   where:
                     candidate.id == ^invitation.id and
                       candidate.organization_id == ^actor.organization_id and
                       is_nil(candidate.accepted_at) and is_nil(candidate.revoked_at) and
                       candidate.expires_at > ^current
                 ),
                 set: [revoked_at: current, updated_at: current]
               ) do
          invitation = Repo.get!(OrganizationInvitation, invitation.id)

          audit!(%{
            actor_id: actor.id,
            organization_id: actor.organization_id,
            event: "invitation.revoked",
            metadata: %{"invitation_id" => invitation.id}
          })

          invitation
        else
          {0, _} -> Repo.rollback(:invalid_invitation)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def get_invitation_by_token(token) when is_binary(token) do
    with {:ok, token} <- decode_token(token) do
      Repo.one(
        from invitation in OrganizationInvitation,
          where: invitation.token_hash == ^hash_token(token),
          preload: [:organization, :inviter]
      )
    else
      :error -> nil
    end
  end

  def accept_invitation(%User{id: user_id}, token) when is_binary(token) do
    with {:ok, raw_token} <- decode_token(token) do
      supplied_hash = hash_token(raw_token)

      Repo.transaction(fn ->
        user = Repo.get!(User, user_id)
        current = now()

        invitation =
          Repo.one(
            from candidate in OrganizationInvitation,
              where: candidate.token_hash == ^supplied_hash,
              preload: :organization
          )

        with %OrganizationInvitation{} <- invitation,
             :ok <- active_invitation(invitation),
             :ok <- invitation_matches_user(invitation, user),
             :ok <- ensure_orgless(user),
             {1, _} <- assign_invited_user(user, invitation, current),
             {1, _} <- accept_active_invitation(invitation, supplied_hash, current) do
          user = Repo.get!(User, user.id)
          invitation = Repo.get!(OrganizationInvitation, invitation.id)
          revoke_user_auth(user.id, broadcast: false)

          audit!(%{
            actor_id: user.id,
            target_user_id: user.id,
            organization_id: invitation.organization_id,
            event: "invitation.accepted",
            metadata: %{"invitation_id" => invitation.id}
          })

          {user, invitation}
        else
          nil -> Repo.rollback(:invalid_invitation)
          {0, _} -> Repo.rollback(:invalid_invitation)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> accept_result()
    else
      :error -> {:error, :invalid_invitation}
    end
  end

  defp assign_invited_user(user, invitation, current) do
    Repo.update_all(
      from(candidate in User,
        where: candidate.id == ^user.id and is_nil(candidate.organization_id)
      ),
      set: [
        organization_id: invitation.organization_id,
        org_role: invitation.role,
        org: invitation.organization.slug,
        updated_at: current
      ]
    )
  end

  defp accept_active_invitation(invitation, supplied_hash, current) do
    Repo.update_all(
      from(candidate in OrganizationInvitation,
        where:
          candidate.id == ^invitation.id and candidate.token_hash == ^supplied_hash and
            is_nil(candidate.accepted_at) and is_nil(candidate.revoked_at) and
            candidate.expires_at > ^current
      ),
      set: [accepted_at: current, updated_at: current]
    )
  end

  def change_role(actor, target_id, role) when role in ~w(owner admin member) do
    with {:ok, actor} <- admin_actor(actor) do
      Repo.transaction(fn ->
        lock_organization!(actor.organization_id)
        target = Repo.get(User, target_id)

        with :ok <- manageable_member(actor, target),
             :ok <- can_assign_role(actor, role),
             :ok <- owner_change_allowed(target, role),
             {:ok, target} <- target |> User.changeset(%{org_role: role}) |> Repo.update() do
          delete_user_sessions(target.id)

          audit!(%{
            actor_id: actor.id,
            target_user_id: target.id,
            organization_id: actor.organization_id,
            event: "member.role_changed",
            metadata: %{"role" => role}
          })

          target
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def change_role(_actor, _target_id, _role), do: {:error, :invalid_role}

  def remove_member(actor, target_id) do
    with {:ok, actor} <- admin_actor(actor) do
      Repo.transaction(fn ->
        lock_organization!(actor.organization_id)
        target = Repo.get(User, target_id)

        with :ok <- manageable_member(actor, target),
             :ok <- owner_removal_allowed(target),
             {:ok, target} <-
               target
               |> User.changeset(%{organization_id: nil, org_role: nil, org: nil})
               |> Repo.update() do
          delete_user_sessions(target.id)

          audit!(%{
            actor_id: actor.id,
            target_user_id: target.id,
            organization_id: actor.organization_id,
            event: "member.removed",
            metadata: %{}
          })

          target
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def authorized_admin?(
        %User{organization_id: organization_id, org_role: role},
        organization_or_id
      ) do
    organization_id == organization_id(organization_or_id) and role in ~w(owner admin)
  end

  def authorized_admin?(_, _), do: false

  def create_session_handoff(%User{} = user, organization_or_id, return_to) do
    case organization_id(organization_or_id) do
      organization_id
      when organization_id == user.organization_id and is_integer(organization_id) ->
        token = raw_token()

        %SessionHandoff{}
        |> SessionHandoff.changeset(%{
          user_id: user.id,
          organization_id: organization_id,
          token_hash: hash_token(token),
          return_to: return_to,
          expires_at: DateTime.add(now(), @handoff_lifetime, :second)
        })
        |> Repo.insert()
        |> case do
          {:ok, handoff} ->
            audit!(%{
              actor_id: user.id,
              target_user_id: user.id,
              organization_id: organization_id,
              event: "session_handoff.created",
              metadata: %{"handoff_id" => handoff.id}
            })

            {:ok, encode_token(token)}

          {:error, changeset} ->
            {:error, changeset}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  def bind_session_handoff(token, expected_organization, %User{id: user_id}, state)
      when is_binary(token) and is_binary(state) do
    with {:ok, token} <- decode_token(token),
         organization_id when is_integer(organization_id) <-
           organization_id(expected_organization) do
      current = now()

      case Repo.update_all(
             from(handoff in SessionHandoff,
               where:
                 handoff.token_hash == ^hash_token(token) and handoff.user_id == ^user_id and
                   handoff.organization_id == ^organization_id and is_nil(handoff.state_hash) and
                   is_nil(handoff.consumed_at) and handoff.expires_at > ^current
             ),
             set: [state_hash: hash_token(state), updated_at: current]
           ) do
        {1, _} -> :ok
        _ -> {:error, :invalid_handoff}
      end
    else
      _ -> {:error, :invalid_handoff}
    end
  end

  def bind_session_handoff(_, _, _, _), do: {:error, :invalid_handoff}

  def consume_session_handoff(token, expected_organization, state)
      when is_binary(token) and is_binary(state) do
    with {:ok, token} <- decode_token(token),
         organization_id when is_integer(organization_id) <-
           organization_id(expected_organization) do
      token_hash = hash_token(token)
      state_hash = hash_token(state)
      current = now()

      case Repo.one(
             from handoff in SessionHandoff,
               join: user in assoc(handoff, :user),
               where:
                 handoff.token_hash == ^token_hash and handoff.state_hash == ^state_hash and
                   handoff.organization_id == ^organization_id and
                   is_nil(handoff.consumed_at) and handoff.expires_at > ^current,
               preload: [user: user]
           ) do
        nil ->
          {:error, :invalid_handoff}

        handoff ->
          {count, _} =
            Repo.update_all(
              from(current_handoff in SessionHandoff,
                where:
                  current_handoff.id == ^handoff.id and
                    current_handoff.token_hash == ^token_hash and
                    current_handoff.state_hash == ^state_hash and
                    is_nil(current_handoff.consumed_at) and current_handoff.expires_at > ^current
              ),
              set: [consumed_at: current, updated_at: current]
            )

          if count == 1, do: {:ok, handoff}, else: {:error, :invalid_handoff}
      end
    else
      _ -> {:error, :invalid_handoff}
    end
  end

  def consume_session_handoff(_, _, _), do: {:error, :invalid_handoff}

  defp invitation_result({:ok, {invitation, token}}), do: {:ok, invitation, token}
  defp invitation_result({:error, reason}), do: {:error, reason}

  defp accept_result({:ok, {user, invitation}}), do: {:ok, user, invitation}
  defp accept_result({:error, reason}), do: {:error, reason}

  defp create_invitation!(actor, email, role) do
    token = raw_token()
    current = now()

    case %OrganizationInvitation{}
         |> OrganizationInvitation.changeset(%{
           organization_id: actor.organization_id,
           email: email,
           role: role,
           inviter_id: actor.id,
           token_hash: hash_token(token),
           expires_at: DateTime.add(current, @invitation_lifetime, :second),
           sent_at: current,
           send_count: 1
         })
         |> Repo.insert() do
      {:ok, invitation} ->
        audit!(%{
          actor_id: actor.id,
          organization_id: actor.organization_id,
          event: "invitation.created",
          metadata: %{"invitation_id" => invitation.id, "role" => role}
        })

        {invitation, encode_token(token)}

      {:error, changeset} ->
        Repo.rollback(changeset)
    end
  end

  defp admin_actor(%User{id: user_id}) do
    case Repo.get(User, user_id) do
      user when is_struct(user, User) and user.org_role in ["owner", "admin"] -> {:ok, user}
      _ -> {:error, :unauthorized}
    end
  end

  defp admin_actor(_), do: {:error, :unauthorized}

  defp invitation_email(attrs) do
    case value(attrs, :email) do
      email when is_binary(email) and email != "" -> {:ok, String.trim(email)}
      _ -> {:error, :invalid_email}
    end
  end

  defp invitation_role(attrs) do
    case value(attrs, :role) do
      role when role in ~w(owner admin member) -> {:ok, role}
      _ -> {:error, :invalid_role}
    end
  end

  defp manageable_invitation(_actor, nil), do: {:error, :not_found}

  defp manageable_invitation(actor, invitation) do
    if invitation.organization_id == actor.organization_id and
         can_assign_role(actor, invitation.role) == :ok do
      :ok
    else
      {:error, :unauthorized}
    end
  end

  defp active_invitation(%OrganizationInvitation{
         accepted_at: accepted_at,
         revoked_at: revoked_at,
         expires_at: expires_at
       }) do
    cond do
      accepted_at -> {:error, :already_accepted}
      revoked_at -> {:error, :revoked}
      DateTime.compare(expires_at, now()) != :gt -> {:error, :expired}
      true -> :ok
    end
  end

  defp active_invitation(_), do: {:error, :not_found}

  defp pending_invitation(organization_id, email) do
    Repo.one(
      from invitation in OrganizationInvitation,
        where:
          invitation.organization_id == ^organization_id and
            invitation.normalized_email == ^normalize_email(email) and
            is_nil(invitation.accepted_at) and is_nil(invitation.revoked_at)
    )
  end

  defp expire_invitations(organization_id) do
    Repo.update_all(
      from(invitation in OrganizationInvitation,
        where:
          invitation.organization_id == ^organization_id and is_nil(invitation.accepted_at) and
            is_nil(invitation.revoked_at) and invitation.expires_at <= ^now()
      ),
      set: [revoked_at: now()]
    )
  end

  defp invitation_matches_user(
         %OrganizationInvitation{normalized_email: invitation_email},
         %User{normalized_email: user_email}
       )
       when invitation_email == user_email,
       do: :ok

  defp invitation_matches_user(_, _), do: {:error, :email_mismatch}

  defp ensure_orgless(%User{organization_id: nil}), do: :ok
  defp ensure_orgless(_), do: {:error, :already_in_organization}

  defp manageable_member(_actor, nil), do: {:error, :not_found}

  defp manageable_member(%User{id: actor_id}, %User{id: actor_id}),
    do: {:error, :self_change_forbidden}

  defp manageable_member(actor, target) do
    cond do
      target.organization_id != actor.organization_id -> {:error, :unauthorized}
      actor.org_role == "owner" -> :ok
      actor.org_role == "admin" and target.org_role == "member" -> :ok
      true -> {:error, :unauthorized}
    end
  end

  defp can_assign_role(%User{org_role: "owner"}, role) when role in ~w(owner admin member),
    do: :ok

  defp can_assign_role(%User{org_role: "admin"}, "member"), do: :ok
  defp can_assign_role(_, _), do: {:error, :unauthorized}

  defp owner_change_allowed(%User{org_role: "owner", organization_id: organization_id}, role)
       when role != "owner" do
    if owner_count(organization_id) > 1, do: :ok, else: {:error, :last_owner}
  end

  defp owner_change_allowed(_, _), do: :ok

  defp owner_removal_allowed(%User{org_role: "owner", organization_id: organization_id}) do
    if owner_count(organization_id) > 1, do: :ok, else: {:error, :last_owner}
  end

  defp owner_removal_allowed(_), do: :ok

  defp lock_organization!(organization_id) do
    query = from organization in Organization, where: organization.id == ^organization_id

    query =
      if to_string(Repo.__adapter__()) == "Elixir.Ecto.Adapters.Postgres" do
        from organization in query, lock: "FOR UPDATE"
      else
        query
      end

    Repo.one!(query)
  end

  defp owner_count(organization_id) do
    Repo.aggregate(
      from(user in User,
        where: user.organization_id == ^organization_id and user.org_role == "owner"
      ),
      :count
    )
  end

  defp organization_and_slug(%Organization{id: id, slug: slug}), do: {id, slug}
  defp organization_and_slug(id) when is_integer(id), do: {id, nil}

  defp organization_and_slug(slug) when is_binary(slug) do
    case Acs.Orgs.get_by_slug(slug) do
      %Organization{id: id} when is_integer(id) -> {id, slug}
      _ -> {nil, slug}
    end
  end

  defp organization_and_slug(_), do: {nil, nil}

  defp organization_id(organization_or_id) do
    organization_or_id |> organization_and_slug() |> elem(0)
  end

  defp value(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp linkable_user_by_email(normalized_email) do
    case Repo.all(
           from user in User,
             where: user.normalized_email == ^normalized_email and is_nil(user.oidc_subject),
             order_by: [asc: user.id],
             limit: 2
         ) do
      [] -> nil
      [user] -> user
      _duplicates -> Repo.rollback(:email_identity_conflict)
    end
  end

  defp oidc_email_claimed?(normalized_email) do
    Repo.exists?(
      from user in User,
        where: user.normalized_email == ^normalized_email and not is_nil(user.oidc_subject)
    )
  end

  defp audit!(attrs) do
    metadata = attrs |> Map.get(:metadata, %{}) |> Jason.encode!()

    %AccountAuditEvent{}
    |> AccountAuditEvent.changeset(Map.put(attrs, :metadata, metadata))
    |> Repo.insert!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp normalize_email(email), do: email |> String.trim() |> String.downcase()

  defp normalize_issuer(issuer) do
    issuer
    |> String.trim()
    |> String.trim_trailing("/")
    |> Kernel.<>("/")
  end

  defp raw_token, do: :crypto.strong_rand_bytes(@token_bytes)
  defp encode_token(token), do: Base.url_encode64(token, padding: false)
  defp hash_token(token), do: :crypto.hash(:sha256, token)
  defp decode_token(token), do: Base.url_decode64(token, padding: false)
end
