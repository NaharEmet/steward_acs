defmodule Acs.MCP.OAuth.JWKSTest do
  use ExUnit.Case, async: true

  alias Acs.MCP.OAuth.JWKS

  test "rejects JWT algorithms outside the configured Auth0 algorithm" do
    header = Base.url_encode64(~s({"alg":"HS256","kid":"test"}), padding: false)
    payload = Base.url_encode64(~s({"sub":"user"}), padding: false)

    assert {:error, "Unsupported JWT signing algorithm"} =
             JWKS.verify("#{header}.#{payload}.signature")
  end
end
