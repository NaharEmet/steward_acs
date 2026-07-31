defmodule AcsWeb.AcsLive.MembersLiveTest do
  use AcsWeb.ConnCase, async: false

  alias Acs.Accounts
  alias Acs.Accounts.{OrganizationInvitation, User}
  alias Acs.Orgs
  alias AcsWeb.UserAuth

  setup %{conn: conn} do
    Acs.Org.clear_request_org()
    organization = Orgs.get_by_slug("default")

    %{conn: Map.put(conn, :host, "localhost"), organization: organization}
  end

  test "an owner chooses an access level when inviting a member", %{
    conn: conn,
    organization: organization
  } do
    owner = member!(organization, "owner")
    conn = log_in(conn, owner)

    assert {:ok, view, _html} = live(conn, "/settings/members")
    assert has_element?(view, "label[for='invite-role']", "Access level")
    assert has_element?(view, "#members-table th", "Access level")
    assert has_element?(view, "#invite-role option[value='member']", "Member")
    assert has_element?(view, "#invite-role option[value='admin']", "Administrator")
    assert has_element?(view, "#invite-role option[value='owner']", "Owner")

    email = unique_email("invited-admin")

    view
    |> form("#invite-form", invitation: %{email: email, role: "admin"})
    |> render_submit()

    invitation = Repo.get_by!(OrganizationInvitation, normalized_email: email)
    assert invitation.organization_id == organization.id
    assert invitation.role == "admin"
    assert has_element?(view, "#invitation-link-recipient", "Administrator access")
    assert has_element?(view, "#pending-invitations-table th", "Access level")
    assert has_element?(view, "#invitation-row-#{invitation.id} .role-admin", "Administrator")
  end

  test "an owner changes another member's access level", %{
    conn: conn,
    organization: organization
  } do
    owner = member!(organization, "owner")
    member = member!(organization, "member")
    member_session = Accounts.generate_user_session_token(member)
    conn = log_in(conn, owner)

    assert {:ok, view, _html} = live(conn, "/settings/members")
    assert has_element?(view, "#role-form-#{member.id} option[value='admin']", "Administrator")

    view
    |> form("#role-form-#{member.id}", %{target_id: member.id, role: "admin"})
    |> render_submit()

    assert Repo.get!(User, member.id).org_role == "admin"
    assert Accounts.get_user_by_session_token(member_session) == nil
    assert has_element?(view, "label[for='member-role-#{member.id}']", "Access level")
    assert has_element?(view, "#member-row-#{member.id} .role-admin", "Administrator")
  end

  test "an administrator can invite members but cannot forge a privileged invitation", %{
    conn: conn,
    organization: organization
  } do
    admin = member!(organization, "admin")
    conn = log_in(conn, admin)

    assert {:ok, view, _html} = live(conn, "/settings/members")
    assert has_element?(view, "#invite-role option[value='member']", "Member")
    refute has_element?(view, "#invite-role option[value='admin']")
    refute has_element?(view, "#invite-role option[value='owner']")

    member_email = unique_email("invited-member")

    view
    |> form("#invite-form", invitation: %{email: member_email, role: "member"})
    |> render_submit()

    member_invitation = Repo.get_by!(OrganizationInvitation, normalized_email: member_email)
    assert member_invitation.organization_id == organization.id
    assert member_invitation.role == "member"

    email = unique_email("forged-admin")

    html =
      render_submit(view, "invite-member", %{
        "invitation" => %{"email" => email, "role" => "admin"}
      })

    assert html =~ "Your account cannot invite this role."
    refute Repo.get_by(OrganizationInvitation, normalized_email: email)
  end

  defp log_in(conn, user) do
    conn
    |> init_test_session(%{})
    |> UserAuth.put_user_session(user)
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

  defp unique_email(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}@example.test"
  end
end
