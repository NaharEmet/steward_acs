defmodule Acs.AccountsOrganizationTest do
  use Acs.DataCase, async: false

  alias Acs.Accounts
  alias Acs.Accounts.{OrganizationInvitation, SessionHandoff, User}
  alias Acs.Orgs
  alias Acs.Orgs.Organization

  describe "OIDC users" do
    test "rejects an OIDC identity with an unverified email" do
      assert {:error, :email_not_verified} =
               Accounts.upsert_oidc_user(%{
                 issuer: "https://issuer.example.test/",
                 subject: "unverified-subject",
                 email: "unverified@example.test",
                 email_verified: false
               })
    end

    test "keeps users with the same subject at different issuers separate" do
      assert {:ok, first} =
               Accounts.upsert_oidc_user(%{
                 issuer: "https://issuer-one.example.test/",
                 subject: "shared-subject",
                 email: unique_email("issuer-one"),
                 email_verified: true
               })

      assert {:ok, second} =
               Accounts.upsert_oidc_user(%{
                 issuer: "https://issuer-two.example.test/",
                 subject: "shared-subject",
                 email: unique_email("issuer-two"),
                 email_verified: true
               })

      assert first.id != second.id
    end
  end

  describe "organization creation" do
    test "creates an organization for an orgless user and makes them its owner" do
      user = orgless_user!()
      attrs = organization_attrs("created-by-user")

      assert {:ok, organization} = Orgs.create_for_user(user, attrs)

      updated_user = Repo.get!(User, user.id)
      assert updated_user.organization_id == organization.id
      assert updated_user.org_role == "owner"
      assert updated_user.org == organization.slug
    end

    test "rejects creating a second organization for a member" do
      user = orgless_user!()

      assert {:ok, _organization} = Orgs.create_for_user(user, organization_attrs("first-org"))

      assert {:error, :already_in_organization} =
               Orgs.create_for_user(user, organization_attrs("second-org"))
    end
  end

  describe "invitations" do
    test "allows an owner to invite an admin" do
      organization = organization!()
      owner = member!(organization, "owner")

      assert {:ok, invitation, token} =
               Accounts.invite_user(owner, %{email: unique_email("invited-admin"), role: "admin"})

      assert invitation.organization_id == organization.id
      assert is_binary(token)
    end

    test "prevents an admin from inviting another admin" do
      organization = organization!()
      admin = member!(organization, "admin")

      assert {:error, :unauthorized} =
               Accounts.invite_user(admin, %{email: unique_email("other-admin"), role: "admin"})
    end

    test "stores only the hash of an invitation token" do
      organization = organization!()
      owner = member!(organization, "owner")

      assert {:ok, invitation, token} =
               Accounts.invite_user(owner, %{email: unique_email("hashed-token"), role: "member"})

      assert {:ok, raw_token} = Base.url_decode64(token, padding: false)
      assert invitation.token_hash == :crypto.hash(:sha256, raw_token)
    end

    test "accepting an invitation assigns the invitee to its organization" do
      organization = organization!()
      owner = member!(organization, "owner")
      invitee = orgless_user!()

      assert {:ok, _invitation, token} =
               Accounts.invite_user(owner, %{email: invitee.email, role: "member"})

      assert {:ok, accepted_user, accepted_invitation} =
               Accounts.accept_invitation(invitee, token)

      assert accepted_user.organization_id == organization.id
      assert accepted_user.org_role == "member"
      assert accepted_invitation.accepted_at
    end

    test "rejects replaying an accepted invitation token" do
      organization = organization!()
      owner = member!(organization, "owner")
      invitee = orgless_user!()

      assert {:ok, _invitation, token} =
               Accounts.invite_user(owner, %{email: invitee.email, role: "member"})

      assert {:ok, _user, _invitation} = Accounts.accept_invitation(invitee, token)
      assert {:error, :already_accepted} = Accounts.accept_invitation(invitee, token)
    end

    test "rejects an expired invitation token" do
      organization = organization!()
      owner = member!(organization, "owner")
      invitee = orgless_user!()

      assert {:ok, invitation, token} =
               Accounts.invite_user(owner, %{email: invitee.email, role: "member"})

      expired_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-1, :second)

      invitation
      |> OrganizationInvitation.changeset(%{expires_at: expired_at})
      |> Repo.update!()

      assert {:error, :expired} = Accounts.accept_invitation(invitee, token)
    end

    test "rejects an invitation accepted by a different email address" do
      organization = organization!()
      owner = member!(organization, "owner")
      invited_user = orgless_user!()
      other_user = orgless_user!()

      assert {:ok, _invitation, token} =
               Accounts.invite_user(owner, %{email: invited_user.email, role: "member"})

      assert {:error, :email_mismatch} = Accounts.accept_invitation(other_user, token)
    end
  end

  describe "membership changes" do
    test "removing a member clears their organization and revokes their sessions" do
      organization = organization!()
      owner = member!(organization, "owner")
      member = member!(organization, "member")
      token = Accounts.generate_user_session_token(member)

      assert {:ok, removed_member} = Accounts.remove_member(owner, member.id)

      assert removed_member.organization_id == nil
      assert removed_member.org_role == nil
      assert Accounts.get_user_by_session_token(token) == nil
    end

    test "prevents demoting the sole organization owner" do
      organization = organization!()
      owner = member!(organization, "owner")

      assert {:error, :self_change_forbidden} = Accounts.change_role(owner, owner.id, "member")
    end
  end

  describe "session handoffs" do
    test "consumes a session handoff only once" do
      organization = organization!()
      user = member!(organization, "member")

      assert {:ok, token} = Accounts.create_session_handoff(user, organization, "/tools")
      assert :ok = Accounts.bind_session_handoff(token, organization, user, "browser-state")
      assert {:ok, handoff} =
               Accounts.consume_session_handoff(token, organization, "browser-state")

      assert handoff.user.id == user.id

      assert {:error, :invalid_handoff} =
               Accounts.consume_session_handoff(token, organization, "browser-state")
    end

    test "rejects a handoff token on a different organization" do
      organization = organization!()
      other_organization = organization!()
      user = member!(organization, "member")

      assert {:ok, token} = Accounts.create_session_handoff(user, organization, "/")

      assert {:error, :invalid_handoff} =
               Accounts.bind_session_handoff(token, other_organization, user, "browser-state")
    end

    test "rejects an expired session handoff" do
      organization = organization!()
      user = member!(organization, "member")

      assert {:ok, token} = Accounts.create_session_handoff(user, organization, "/")

      expired_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-1, :second)

      SessionHandoff
      |> Repo.one!()
      |> SessionHandoff.changeset(%{expires_at: expired_at})
      |> Repo.update!()

      assert {:error, :invalid_handoff} =
               Accounts.bind_session_handoff(token, organization, user, "browser-state")
    end
  end

  describe "global sessions" do
    test "finds a session token regardless of the requested organization" do
      organization = organization!()
      user = member!(organization, "member")
      token = Accounts.generate_user_session_token(user)

      assert Accounts.get_user_by_session_token(token, "different-organization").id == user.id
    end
  end

  defp orgless_user! do
    {:ok, user} = Accounts.register_user(%{email: unique_email("orgless")})
    user
  end

  defp member!(organization, role) do
    {:ok, user} =
      Accounts.register_user(%{
        email: unique_email(role),
        org: organization.slug,
        organization_id: organization.id,
        org_role: role
      })

    user
  end

  defp organization! do
    Repo.insert!(Organization.changeset(%Organization{}, organization_attrs("organization")))
  end

  defp organization_attrs(prefix) do
    suffix = System.unique_integer([:positive])
    slug = "#{prefix}-#{suffix}"

    %{
      name: "#{String.capitalize(prefix)} #{suffix}",
      slug: slug,
      subdomain: slug,
      provisioning_status: "ready"
    }
  end

  defp unique_email(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}@example.test"
  end
end
