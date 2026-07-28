defmodule Acs.LLMTest do
  use ExUnit.Case, async: true

  alias Acs.LLM

  describe "extract_json_content/1" do
    test "returns decoded map for valid JSON" do
      content =
        ~S({"quality_score": 4, "title_quality": 5, "is_noise": false, "recommendation": "approve", "reasoning": "Good memory entry.", "improvements": "None", "suggested_title": "Test title", "is_duplicate_of": null})

      assert {:ok, decoded} = LLM.extract_json_content(content)
      assert decoded["recommendation"] == "approve"
      assert decoded["is_duplicate_of"] == nil
    end

    test "handles JSON with nested objects correctly" do
      content = ~S({"level1": {"level2": {"value": 42}}, "recommendation": "approve"})
      assert {:ok, decoded} = LLM.extract_json_content(content)
      assert decoded["recommendation"] == "approve"
    end

    test "extracts JSON from markdown code blocks" do
      content = """
      Here is the evaluation:
      ```json
      {"quality_score": 5, "recommendation": "approve"}
      ```
      """

      assert {:ok, decoded} = LLM.extract_json_content(content)
      assert decoded["quality_score"] == 5
    end

    test "extracts JSON with thinking tags" do
      content = """
      <thinking>Let me evaluate this memory...</thinking>
      {"quality_score": 3, "recommendation": "human_review"}
      """

      assert {:ok, decoded} = LLM.extract_json_content(content)
      assert decoded["quality_score"] == 3
    end

    test "handles content with text before JSON using balanced extraction" do
      content = ~S(Some text before {"quality_score": 4, "recommendation": "approve"})
      assert {:ok, decoded} = LLM.extract_json_content(content)
      assert decoded["recommendation"] == "approve"
    end

    test "returns error for content with no JSON" do
      content = "This is just plain text with no JSON structure at all."
      assert LLM.extract_json_content(content) == :error
    end
  end

  describe "usage_tokens/1" do
    test "reads llm_utils normalized usage keys" do
      assert {10, 4, 14} =
               LLM.usage_tokens(%{usage: %{tokens_in: 10, tokens_out: 4, total_tokens: 14}})
    end

    test "falls back to prompt/completion aliases" do
      assert {3, 2, 5} =
               LLM.usage_tokens(%{"usage" => %{"prompt_tokens" => 3, "completion_tokens" => 2}})
    end
  end

  describe "normalize_error_type/1" do
    test "maps common provider failures to stable classes" do
      assert LLM.normalize_error_type(:timeout) == "timeout"
      assert LLM.normalize_error_type({:rate_limited, "x", nil}) == "rate_limited"

      assert LLM.normalize_error_type(
               {:server_error, 503, "ResourceExhausted: Worker local total request limit reached"}
             ) == "capacity"
    end
  end
end
