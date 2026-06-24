defmodule Acs.MCP.Plugs.AuthStrategy do
  @moduledoc """
  Behaviour for MCP authentication strategies.

  Implementations return `{:ok, %{role: String.t(), org_id: String.t() | nil, permissions: [String.t()] | nil}}`
  or `{:error, reason}`.
  """
  @callback authenticate(key :: String.t(), conn :: Plug.Conn.t()) ::
              {:ok, %{role: String.t(), org_id: String.t() | nil, permissions: [String.t()] | nil}}
              | {:error, String.t()}
end
