defmodule Acs.MCP.OAuth.WellKnown do
  @moduledoc """
  Serves RFC 9728 OAuth Protected Resource Metadata for MCP clients (Claude Connectors).
  """

  import Plug.Conn

  alias Acs.MCP.OAuth.Config

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: path} = conn, _opts) do
    if path == Config.protected_resource_metadata_path() and Config.enabled?() do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(metadata(conn)))
      |> halt()
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(404, Jason.encode!(%{error: "Not found"}))
      |> halt()
    end
  end

  defp metadata(conn) do
    %{
      "resource" => Config.resource_url(conn),
      "authorization_servers" => [Config.authorization_server(conn)],
      "bearer_methods_supported" => ["header"],
      "scopes_supported" => Config.scopes_supported()
    }
  end
end
