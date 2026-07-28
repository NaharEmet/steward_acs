defmodule Acs.Skills.IntakeTest do
  use ExUnit.Case, async: true

  alias Acs.Skills.Intake

  test "good procedural skill is allowed with no questions" do
    {:ok, review} =
      Intake.review(%{
        "name" => "rotate-vault-token",
        "description" => "Rotate Infisical service token",
        "when_to_use" => "When Infisical token is expiring",
        "content" => """
        ## Prerequisites
        - Infisical CLI logged in

        ## Steps
        1. List tokens in the project
        2. Create a new service token
        3. Update host `.infisical.env` and restart compose
        4. Revoke the old token

        ## Verification
        - `infisical secrets` succeeds on the host
        """
      })

    assert review.allow
    assert review.questions == []
    assert review.source == :heuristic
    refute review.suggested_sensitive
  end

  test "embedded api key blocks with sensitive question" do
    {:ok, review} =
      Intake.review(%{
        "name" => "bad-secret-skill",
        "content" => """
        1. Set api_key: sk-live-ABCDEFGHijklmnop
        2. Call the API
        """
      })

    assert review.suggested_sensitive
    refute review.allow
    assert Enum.any?(review.questions, &(&1["id"] == "sensitive"))
  end

  test "one-liner without steps asks needs_improvement" do
    {:ok, review} =
      Intake.review(%{
        "name" => "axiom-as-skill",
        "content" => "Never force push to main."
      })

    refute review.allow
    assert review.needs_improvement
    assert Enum.any?(review.questions, &(&1["id"] == "needs_improvement"))
  end

  test "mentions secrets tooling without embedding secrets — allow" do
    {:ok, review} =
      Intake.review(%{
        "name" => "use-infisical",
        "content" => """
        1. Put secrets in Infisical, not in git
        2. Export via `infisical run -- npm start`
        3. Rotate the service token quarterly
        """
      })

    assert review.allow
    assert review.questions == []
    refute review.suggested_sensitive
  end
end
