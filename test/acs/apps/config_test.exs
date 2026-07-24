defmodule Acs.Apps.ConfigTest do
  use ExUnit.Case, async: false

  alias Acs.Apps.Config

  test "keeps app credentials isolated by organization" do
    name = "app-#{System.unique_integer([:positive])}"
    org_a = "config-org-a"
    org_b = "config-org-b"

    on_exit(fn ->
      Config.remove_app(name, org_a)
      Config.remove_app(name, org_b)
    end)

    assert :ok = Config.configure_app(name, [base_url: "https://a.example", api_key: "a"], org_a)
    assert :ok = Config.configure_app(name, [base_url: "https://b.example", api_key: "b"], org_b)

    assert Config.get_app(name, org_a)[:api_key] == "a"
    assert Config.get_app(name, org_b)[:api_key] == "b"
    assert Map.keys(Config.list_apps(org_a)) == [name]
    assert Map.keys(Config.list_apps(org_b)) == [name]

    assert :ok = Config.remove_app(name, org_a)
    assert Config.get_app(name, org_a) == nil
    assert Config.get_app(name, org_b)[:api_key] == "b"
  end
end
