defmodule Acs.LLMTest do
  use ExUnit.Case, async: true

  alias Acs.LLM

  describe "extract_json_content/1" do
    test "returns decoded map for valid JSON" do
      content = ~S({"quality_score": 4, "title_quality": 5, "is_noise": false, "recommendation": "approve", "reasoning": "Good memory entry.", "improvements": "None", "suggested_title": "Test title", "is_duplicate_of": null})
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
end
