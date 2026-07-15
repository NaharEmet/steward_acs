defmodule Acs.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias Acs.ConfigEnv
  alias Acs.Prompts

  describe "parse_org_dashboard_creds/1" do
    test "returns empty map for nil, empty, or whitespace" do
      assert ConfigEnv.parse_org_dashboard_creds(nil) == %{}
      assert ConfigEnv.parse_org_dashboard_creds("") == %{}
      assert ConfigEnv.parse_org_dashboard_creds("   ") == %{}
    end

    test "parses valid org credential map" do
      json = ~S({"prod":{"username":"admin","password":"secret"},"demo":{"username":"u","password":"p"}})

      assert ConfigEnv.parse_org_dashboard_creds(json) == %{
               "prod" => %{username: "admin", password: "secret"},
               "demo" => %{username: "u", password: "p"}
             }
    end

    test "raises with message for invalid JSON" do
      assert_raise ArgumentError, ~r/not valid JSON/, fn ->
        ConfigEnv.parse_org_dashboard_creds("{not json")
      end
    end

    test "raises with message for non-object JSON" do
      assert_raise ArgumentError, ~r/must be a JSON object/, fn ->
        ConfigEnv.parse_org_dashboard_creds("[1,2]")
      end
    end

    test "raises with message for malformed org entry" do
      assert_raise ArgumentError, ~r/"prod" must be a JSON object/, fn ->
        ConfigEnv.parse_org_dashboard_creds(~S({"prod":"bad"}))
      end
    end
  end

  describe "Prompts.load/3 for memory evaluate" do
    test "loads builtin memory evaluate prompt" do
      content = Prompts.load("memory", "evaluate", default: "fallback")
      assert is_binary(content)
      assert content != "fallback"
      assert String.contains?(content, "memory")
    end
  end
end
