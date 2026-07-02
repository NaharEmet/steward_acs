defmodule Acs.MCP.UrlSafetyTest do
  use ExUnit.Case, async: false

  alias Acs.MCP.UrlSafety

  setup do
    original = Application.get_env(:steward_acs, :bridge_allowed_hosts, [])
    Application.put_env(:steward_acs, :bridge_allowed_hosts, [])

    on_exit(fn ->
      Application.put_env(:steward_acs, :bridge_allowed_hosts, original)
    end)

    :ok
  end

  describe "validate_outbound_url/1" do
    test "allows public https URLs" do
      # Use a public IP literal to avoid DNS dependency in CI/sandbox
      assert :ok = UrlSafety.validate_outbound_url("https://93.184.216.34/")
    end

    test "rejects localhost" do
      assert {:error, _} = UrlSafety.validate_outbound_url("http://localhost:4000/api")
    end

    test "rejects private IP literals" do
      assert {:error, _} = UrlSafety.validate_outbound_url("http://192.168.1.1/status")
      assert {:error, _} = UrlSafety.validate_outbound_url("http://10.0.0.5/internal")
      assert {:error, _} = UrlSafety.validate_outbound_url("http://127.0.0.1/secret")
    end

    test "rejects metadata endpoint" do
      assert {:error, _} = UrlSafety.validate_outbound_url("http://169.254.169.254/latest/meta-data")
    end

    test "rejects non-http schemes" do
      assert {:error, _} = UrlSafety.validate_outbound_url("file:///etc/passwd")
    end

    test "enforces allowlist when configured" do
      original = Application.get_env(:steward_acs, :bridge_allowed_hosts)
      Application.put_env(:steward_acs, :bridge_allowed_hosts, ["api.example.com"])

      on_exit(fn ->
        Application.put_env(:steward_acs, :bridge_allowed_hosts, original)
      end)

      assert :ok = UrlSafety.validate_outbound_url("https://api.example.com/hook")
      assert {:error, msg} = UrlSafety.validate_outbound_url("https://evil.example.com/hook")
      assert msg =~ "BRIDGE_ALLOWED_HOSTS"
    end
  end
end
