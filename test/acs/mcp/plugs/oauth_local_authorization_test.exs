defmodule Acs.MCP.Plugs.OAuthLocalAuthorizationTest.OIDCStrategy do
  @behaviour Acs.MCP.Plugs.AuthStrategy

  @impl true
  def authenticate(_key, _conn) do
    {:ok,
     %{
       role: "collaborator",
       org_id: nil,
       permissions: ["mcp:tools"],
       agent_identity: "oidc-member@example.test",
       oidc_issuer: "https://issuer.example.test/",
       oidc_subject: "oidc-member-subject",
       email: "oidc-member@example.test",
       allowed_teams: nil,
       allowed_projects: nil
     }}
  end
end

defmodule Acs.MCP.Plugs.OAuthLocalAuthorizationTest.OIDCEmailFallbackStrategy do
  @behaviour Acs.MCP.Plugs.AuthStrategy

  @impl true
  def authenticate(_key, _conn) do
    {:ok,
     %{
       role: "collaborator",
       org_id: nil,
       permissions: ["mcp:tools"],
       agent_identity: "oidc-member@example.test",
       oidc_issuer: "https://issuer.example.test/",
       # Different Auth0 connection than the one stored on the user (e.g. email vs Google).
       oidc_subject: "email|other-connection-subject",
       email: "oidc-member@example.test",
       allowed_teams: nil,
       allowed_projects: nil
     }}
  end
end

defmodule Acs.MCP.Plugs.OAuthLocalAuthorizationTest do
  use Acs.DataCase, async: false

  alias Acs.Accounts
  alias Acs.MCP.Plugs.MCPAuth
  alias Acs.Orgs.Organization

  setup do
    original_strategies = Application.fetch_env(:steward_acs, :auth_strategies)

    Application.put_env(:steward_acs, :auth_strategies, [
      Acs.MCP.Plugs.OAuthLocalAuthorizationTest.OIDCStrategy
    ])

    Acs.Org.clear_request_org()

    on_exit(fn ->
      case original_strategies do
        {:ok, strategies} -> Application.put_env(:steward_acs, :auth_strategies, strategies)
        :error -> Application.delete_env(:steward_acs, :auth_strategies)
      end

      Acs.Org.clear_request_org()
    end)

    :ok
  end

  test "uses the local member role and organization for a validated OIDC identity" do
    organization = organization!()

    {:ok, _user} =
      Accounts.register_user(%{
        email: "oidc-member@example.test",
        first_name: "Ada",
        last_name: "Lovelace",
        org: organization.slug,
        organization_id: organization.id,
        org_role: "member",
        oidc_issuer: "https://issuer.example.test/",
        oidc_subject: "oidc-member-subject"
      })

    result =
      Plug.Test.conn(:get, "/mcp/v1/messages")
      |> Plug.Conn.assign(:current_org, organization.slug)
      |> MCPAuth.call([])

    assert result.assigns.agent_role == "collaborator"
    assert result.assigns.agent_org_id == organization.slug
    assert result.assigns.agent_identity == "Ada Lovelace"
  end

  test "rejects a validated OIDC identity with no local user" do
    organization = organization!()

    result =
      Plug.Test.conn(:get, "/mcp/v1/messages")
      |> Plug.Conn.assign(:current_org, organization.slug)
      |> MCPAuth.call([])

    assert %Plug.Conn{halted: true, status: 401} = result

    assert Jason.decode!(result.resp_body)["error"] ==
             "OAuth user is not authorized for this organization"
  end

  test "authorizes when Auth0 subject differs but email matches the local user" do
    organization = organization!()

    {:ok, _user} =
      Accounts.register_user(%{
        email: "oidc-member@example.test",
        name: "Casey Member",
        org: organization.slug,
        organization_id: organization.id,
        org_role: "member",
        oidc_issuer: "https://issuer.example.test/",
        oidc_subject: "google-oauth2|stored-subject"
      })

    Application.put_env(:steward_acs, :auth_strategies, [
      Acs.MCP.Plugs.OAuthLocalAuthorizationTest.OIDCEmailFallbackStrategy
    ])

    result =
      Plug.Test.conn(:get, "/mcp/v1/messages")
      |> Plug.Conn.assign(:current_org, organization.slug)
      |> MCPAuth.call([])

    assert result.assigns.agent_role == "collaborator"
    assert result.assigns.agent_org_id == organization.slug
    assert result.assigns.agent_identity == "Casey Member"
  end

  test "carries the local user's data authority into the request assigns" do
    organization = organization!()
    Acs.AuthorityLevels.ensure_defaults!(organization.slug)

    {:ok, user} =
      Accounts.register_user(%{
        email: "oidc-member@example.test",
        name: "Cleared Member",
        org: organization.slug,
        organization_id: organization.id,
        org_role: "member",
        oidc_issuer: "https://issuer.example.test/",
        oidc_subject: "oidc-member-subject"
      })

    user
    |> Acs.Accounts.User.changeset(%{authority_level_slug: "elevated"})
    |> Repo.update!()

    result =
      Plug.Test.conn(:get, "/mcp/v1/messages")
      |> Plug.Conn.assign(:current_org, organization.slug)
      |> MCPAuth.call([])

    assert result.assigns.agent_authority_level == "elevated"
    # Executive=1, Senior=2, Standard=3 — clearance, not org role.
    assert result.assigns.agent_authority_sort_order == 2
  end

  test "falls back to email local-part when user has no name fields" do
    organization = organization!()

    {:ok, _user} =
      Accounts.register_user(%{
        email: "oidc-member@example.test",
        org: organization.slug,
        organization_id: organization.id,
        org_role: "member",
        oidc_issuer: "https://issuer.example.test/",
        oidc_subject: "oidc-member-subject"
      })

    result =
      Plug.Test.conn(:get, "/mcp/v1/messages")
      |> Plug.Conn.assign(:current_org, organization.slug)
      |> MCPAuth.call([])

    assert result.assigns.agent_identity == "oidc-member"
  end

  defp organization! do
    suffix = System.unique_integer([:positive])
    slug = "oauth-org-#{suffix}"

    Repo.insert!(
      Organization.changeset(%Organization{}, %{
        name: "OAuth organization #{suffix}",
        slug: slug,
        subdomain: slug,
        provisioning_status: "ready"
      })
    )
  end
end
