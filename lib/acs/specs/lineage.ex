defmodule Acs.Specs.Lineage do
  @moduledoc """
  Builds Git-like replacement links between spec and document entries.

  The old entry is deprecated and points to its replacement with
  `replaced_by`; the replacement points back with `replaces`.
  """

  alias Acs.Specs.Entry

  @doc "Deprecate an approved entry and add bidirectional replacement references."
  def deprecate(%Entry{} = entry, %Entry{} = replacement) do
    cond do
      entry.app == replacement.app and entry.id == replacement.id ->
        {:error, :same_entry}

      entry.status != "approved" ->
        {:error, :entry_not_approved}

      replacement.status != "approved" ->
        {:error, :replacement_not_approved}

      true ->
        old_ref = reference("replaced_by", replacement, "Replaced by")
        new_ref = reference("replaces", entry, "Replaces")

        {:ok, add_reference(%{entry | status: "deprecated"}, old_ref),
         add_reference(replacement, new_ref)}
    end
  end

  defp reference(type, %Entry{} = entry, prefix) do
    %{
      "type" => type,
      "target" => target(entry),
      "description" => "#{prefix} #{entry.title || entry.id}"
    }
  end

  defp target(%Entry{app: app, id: id}), do: "#{app}/#{id}"

  defp add_reference(%Entry{} = entry, reference) do
    references =
      (entry.references || [])
      |> Enum.reject(&(&1["type"] == reference["type"] and &1["target"] == reference["target"]))

    %{entry | references: references ++ [reference]}
  end
end
