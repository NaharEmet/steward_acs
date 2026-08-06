defmodule Acs.ClaimContextTest do
  use ExUnit.Case, async: false

  alias Acs.ClaimContext

  test "Auth0/ChatGPT task surfaces auth0-users, not catalog filler" do
    result =
      ClaimContext.for_task(%{
        "title" => "Fix ChatGPT Auth0 callback URL mismatch",
        "description" => "",
        "file_paths" => []
      })

    names = Enum.map(result.relevant_skills, & &1.name)
    assert "auth0-users" in names
    refute "analyze-agent-ops" in names
    refute "deployment" in names
    refute "choose-knowledge-store" in names
  end

  test "empty title yields no skills or specs" do
    result = ClaimContext.for_task(%{"title" => "", "file_paths" => []})
    assert result.relevant_skills == []
    assert result.relevant_specs == []
  end

  test "for_scope with blank scope does not dump catalog" do
    assert ClaimContext.for_scope("") == %{relevant_skills: [], relevant_specs: []}
  end

  test "meaningful_tokens drops stopwords" do
    tokens = ClaimContext.meaningful_tokens("Fix ChatGPT Auth0 callback URL mismatch")
    assert "auth0" in tokens
    assert "chatgpt" in tokens
    refute "fix" in tokens
  end
end
