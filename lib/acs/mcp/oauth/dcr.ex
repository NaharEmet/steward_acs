defmodule Acs.MCP.OAuth.DCR do
  @moduledoc """
  OIDC Dynamic Client Registration for Claude Connectors.

  When `OAUTH_FIXED_DCR_CLIENT_ID` is set, always returns that Auth0 app
  instead of creating a new third-party client on every connect (which
  exhausts free Auth0 tenants with `too_many_entities`).
  """

  import Plug.Conn

  alias Acs.MCP.OAuth.Config

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{method: "POST", request_path: "/oidc/register"} = conn, _opts) do
    body = conn.body_params || %{}

    case Config.fixed_dcr_client_id() do
      client_id when is_binary(client_id) and client_id != "" ->
        respond_fixed(conn, client_id, body)

      _ ->
        respond_misconfigured(conn)
    end
  end

  def call(conn, _opts), do: conn

  defp respond_fixed(conn, client_id, body) do
    name = Map.get(body, "client_name") || Map.get(body, :client_name) || "Claude"
    redirects = Map.get(body, "redirect_uris") || Map.get(body, :redirect_uris) || []

    payload = %{
      client_id: client_id,
      client_id_issued_at: System.system_time(:second),
      client_name: name,
      client_secret_expires_at: 0,
      grant_types: ["authorization_code", "refresh_token"],
      redirect_uris: List.wrap(redirects),
      response_types: ["code"],
      token_endpoint_auth_method: "none"
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(201, Jason.encode!(payload))
    |> halt()
  end

  defp respond_misconfigured(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      503,
      Jason.encode!(%{
        error: "invalid_client_metadata",
        error_description: "Set OAUTH_FIXED_DCR_CLIENT_ID to a first-party Auth0 application id"
      })
    )
    |> halt()
  end
end
