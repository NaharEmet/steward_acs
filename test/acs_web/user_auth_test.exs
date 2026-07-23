defmodule AcsWeb.UserAuthTest do
  use AcsWeb.ConnCase, async: false

  alias Acs.Accounts
  alias Acs.Orgs.Organization
  alias AcsWeb.UserAuth

  setup do
    Acs.Org.clear_request_org()
    :ok
  end

  describe "require_tenant_user/2" do
    test "allows a member of the ready tenant organization" do
      organization = organization!()
      user = member!(organization, "member")

      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.assign(:current_user, user)
        |> Plug.Conn.assign(:current_org, organization.slug)

      result = UserAuth.require_tenant_user(conn, [])

      refute result.halted
      assert Acs.Org.current() == organization.slug
    end

    test "returns not found when the user belongs to a different tenant" do
      organization = organization!()
      other_organization = organization!()
      user = member!(organization, "member")

      conn =
        Plug.Test.conn(:get, "/")
        |> Plug.Conn.assign(:current_user, user)
        |> Plug.Conn.assign(:current_org, other_organization.slug)

      assert %Plug.Conn{halted: true, status: 404, resp_body: "not found"} =
               UserAuth.require_tenant_user(conn, [])
    end
  end

  describe "require_org_admin/2" do
    test "allows an organization admin on their tenant" do
      organization = organization!()
      admin = member!(organization, "admin")

      conn =
        Plug.Test.conn(:get, "/settings/members")
        |> Plug.Conn.assign(:current_user, admin)
        |> Plug.Conn.assign(:current_org, organization.slug)

      result = UserAuth.require_org_admin(conn, [])

      refute result.halted
    end

    test "returns forbidden for a tenant member without an admin role" do
      organization = organization!()
      member = member!(organization, "member")

      conn =
        Plug.Test.conn(:get, "/settings/members")
        |> Plug.Conn.assign(:current_user, member)
        |> Plug.Conn.assign(:current_org, organization.slug)

      assert %Plug.Conn{halted: true, status: 403, resp_body: "forbidden"} =
               UserAuth.require_org_admin(conn, [])
    end
  end

  defp member!(organization, role) do
    {:ok, user} =
      Accounts.register_user(%{
        email: "#{role}-#{System.unique_integer([:positive])}@example.test",
        org: organization.slug,
        organization_id: organization.id,
        org_role: role
      })

    user
  end

  defp organization! do
    suffix = System.unique_integer([:positive])
    slug = "tenant-#{suffix}"

    Repo.insert!(
      Organization.changeset(%Organization{}, %{
        name: "Tenant #{suffix}",
        slug: slug,
        subdomain: slug,
        provisioning_status: "ready"
      })
    )
  end
end
