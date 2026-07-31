defmodule Acs.MCP.OAuth.ConfigTest do
  use ExUnit.Case, async: true

  alias Acs.MCP.OAuth.Config

  test "assert_runtime_allowed! raises when OAuth is on in single-tenant mode" do
    assert_raise RuntimeError, ~r/not supported in single-tenant mode/, fn ->
      Config.assert_runtime_allowed!(true, false)
    end
  end

  test "assert_runtime_allowed! allows OAuth only with multi-tenant" do
    assert :ok = Config.assert_runtime_allowed!(true, true)
    assert :ok = Config.assert_runtime_allowed!(false, false)
    assert :ok = Config.assert_runtime_allowed!(false, true)
  end
end
