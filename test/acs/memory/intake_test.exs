defmodule Acs.Memory.IntakeTest do
  use ExUnit.Case, async: true

  alias Acs.Memory.Intake

  test "heuristic flags revenue as sensitive" do
    {:ok, review} =
      Intake.review(%{
        "title" => "Q2 ARR",
        "content" => "ARR is $12M because of enterprise expansion",
        "kind" => "learning",
        "scope_path" => "acme/finance"
      })

    assert review.suggested_sensitive
    assert review.source == :heuristic
    assert Enum.any?(review.questions, &(&1["id"] == "sensitive"))
  end

  test "heuristic asks scope when about entity lacks visibility" do
    {:ok, review} =
      Intake.review(%{
        "title" => "Acme prefers net-30",
        "content" => "Acme Corp payment terms are net-30",
        "kind" => "learning",
        "scope_path" => "acme/sales",
        "about_type" => "company",
        "about_name" => "Acme Corp"
      })

    assert Enum.any?(review.questions, &(&1["id"] == "scope"))
  end
end
