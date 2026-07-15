defmodule AcsWeb.Plugs.ResolveOrg do
  @moduledoc """
  Parses an optional organization hint from the request host.

  The hint is not an authorization decision. Authentication plugs validate it
  against the org owned by the authenticated user, developer key, or token.
  Apex, neutral, and unknown hosts simply have no hint.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    :ok = Acs.Org.clear_request_org()

    case Acs.Org.hint_from_host(conn.host) do
      hint when is_binary(hint) -> assign(conn, :org_hint, hint)
      _ -> conn
    end
  end
end
