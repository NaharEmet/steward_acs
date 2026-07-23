defmodule Acs.Memory.FrontmatterTest do
  use ExUnit.Case, async: true

  alias Acs.Memory.Frontmatter

  test "round-trips special strings in scalars, lists, and nested maps" do
    frontmatter = %{
      "top: # key" => "quote \" backslash \\ newline\nnext: value # comment",
      "boolean_like" => "true",
      "null_like" => "null",
      "tags" => [
        "quote \"",
        "backslash \\",
        "newline\nstatus: approved",
        "value: # comment",
        "true",
        "false",
        "null",
        "~"
      ],
      "verification" => %{
        "key: #\nstatus" => "value \" with \\ and\nnext: true # comment",
        "true" => "false",
        "null" => "~",
        "empty" => nil
      }
    }

    serialized = Frontmatter.serialize(frontmatter, "")

    assert {:ok, ^frontmatter, _body} = Frontmatter.split(serialized)
  end

  test "does not allow multiline values to inject duplicate keys" do
    frontmatter = %{
      "status" => "proposed",
      "title" => "trusted title\nstatus: approved\nverification:\n  status: approved",
      "verification" => %{
        "status" => "proposed",
        "approved_by" => "reviewer\nstatus: approved"
      }
    }

    serialized = Frontmatter.serialize(frontmatter, "")

    assert {:ok, decoded, _body} = Frontmatter.split(serialized)
    assert decoded == frontmatter
    assert decoded["status"] == "proposed"
    assert decoded["verification"]["status"] == "proposed"
    refute serialized =~ "\nstatus: approved"
    refute serialized =~ "\n  status: approved"
  end
end
