defmodule Acs.Auth0.McpRoleTest do
  use ExUnit.Case, async: true

  alias Acs.Auth0.McpRole

  test "ensure_for_email_async is a no-op when Management API is not configured" do
    assert :ok = McpRole.ensure_for_email_async("someone@example.com")
  end

  test "ensure_for_email_async ignores blank email" do
    assert :ok = McpRole.ensure_for_email_async("")
    assert :ok = McpRole.ensure_for_email_async(nil)
  end

  test "ensure_for_email rejects blank email" do
    assert {:error, :invalid_email} = McpRole.ensure_for_email("")
  end
end
