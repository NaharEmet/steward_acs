defmodule Acs.AccountsOrganizationHelpersTest do
  use Acs.DataCase, async: false

  alias Acs.Accounts
  alias Acs.Accounts.{User, UserOrganization}
  alias Acs.Orgs.Organization

  describe "organizations_for_user/1" do
    test "returns all organizations a user belongs to" do
      user = user_with_orgs!("multi-org-user@example.test", 2)
      orgs = Accounts.organizations_for_user(user)

      assert length(orgs) == 2
      assert Enum.all?(orgs, &is_struct(&1, Organization))
    end

    test "returns [] for a user with no organizations" do
      user = insert_user!("orgless@example.test")
      assert Accounts.organizations_for_user(user) == []
    end
  end

  describe "user_in_organization?/2" do
    test "returns true for a member" do
      org = insert_org!("test-org")
      user = insert_user!("member@example.test")
      insert_user_org!(user.id, org.id, "member")

      assert Accounts.user_in_organization?(user, org) == true
    end

    test "returns false for a non-member" do
      org = insert_org!("test-org")
      user = insert_user!("non-member@example.test")

      assert Accounts.user_in_organization?(user, org) == false
    end

    test "returns false for nil user or org" do
      assert Accounts.user_in_organization?(nil, %Organization{}) == false
      assert Accounts.user_in_organization?(%User{}, nil) == false
    end
  end

  describe "get_organization_role/2" do
    test "returns the correct role string for a member" do
      org = insert_org!("test-org")
      user = insert_user!("owner@example.test")
      insert_user_org!(user.id, org.id, "owner")

      assert Accounts.get_organization_role(user, org) == "owner"
    end

    test "returns nil for a non-member" do
      org = insert_org!("test-org")
      user = insert_user!("non-member@example.test")

      assert Accounts.get_organization_role(user, org) == nil
    end

    test "returns nil for nil inputs" do
      assert Accounts.get_organization_role(nil, %Organization{}) == nil
      assert Accounts.get_organization_role(%User{}, nil) == nil
    end
  end

  describe "get_user_by_email_and_org/2" do
    test "finds a user by email in a specific org" do
      org = insert_org!("test-org")
      user = insert_user!("found@example.test")
      insert_user_org!(user.id, org.id, "member")

      found = Accounts.get_user_by_email_and_org("found@example.test", org)
      assert found.id == user.id
    end

    test "returns nil if user exists globally but not in that org" do
      org = insert_org!("test-org")
      _user = insert_user!("notinorg@example.test")

      assert Accounts.get_user_by_email_and_org("notinorg@example.test", org) == nil
    end

    test "returns nil for invalid org or email" do
      assert Accounts.get_user_by_email_and_org("any@example.test", nil) == nil
      assert Accounts.get_user_by_email_and_org(nil, %Organization{id: 1}) == nil
    end
  end

  # --- fixtures ---

  defp insert_user!(email) do
    {:ok, user} =
      Accounts.register_user(%{
        email: email,
        org: "default",
        organization_id: nil,
        org_role: nil
      })

    user
  end

  defp insert_org!(name) do
    suffix = System.unique_integer([:positive])
    slug = "#{name}-#{suffix}"

    Repo.insert!(Organization.changeset(%Organization{}, %{
      name: "#{name} #{suffix}",
      slug: slug,
      subdomain: slug,
      provisioning_status: "ready"
    }))
  end

  defp insert_user_org!(user_id, org_id, role) do
    %UserOrganization{}
    |> UserOrganization.changeset(%{
      user_id: user_id,
      organization_id: org_id,
      org_role: role
    })
    |> Repo.insert!()
  end

  defp user_with_orgs!(email, count) do
    user = insert_user!(email)

    for _ <- 1..count do
      org = insert_org!("user-org")
      insert_user_org!(user.id, org.id, "member")
    end

    user
  end
end
