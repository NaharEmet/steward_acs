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
