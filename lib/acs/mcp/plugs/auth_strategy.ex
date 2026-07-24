defmodule Acs.MCP.Plugs.AuthStrategy do
  @moduledoc """
  Behaviour for MCP authentication strategies.

  Implementations return `{:ok, %{role: String.t(), org_id: String.t() | nil, permissions: [String.t()] | nil}}`
  or `{:error, reason}`. OIDC strategies may additionally return validated
  `:oidc_issuer`, `:oidc_subject`, and `:email` claims for local authorization.
  """
  @callback authenticate(key :: String.t(), conn :: Plug.Conn.t()) ::
              {:ok,
               %{
                 required(:role) => String.t(),
                 required(:org_id) => String.t() | nil,
                 required(:permissions) => [String.t()] | nil,
                 optional(:agent_identity) => String.t() | nil,
                 optional(:allowed_teams) => term(),
                 optional(:allowed_projects) => term(),
                 optional(:oidc_issuer) => String.t() | nil,
                 optional(:oidc_subject) => String.t() | nil,
                 optional(:email) => String.t() | nil
               }}
              | {:error, String.t()}
end
