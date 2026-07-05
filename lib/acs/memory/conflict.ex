defmodule Acs.Memory.Conflict do
  @moduledoc """
  Detects potential conflicts when proposing new memories.

  Uses tag overlap and scope proximity to flag memories that
  may contradict or duplicate existing ones.
  """

  @tag_overlap_threshold 3

  @doc """
  Checks a proposed memory for potential conflicts with existing
  approved memories at the same scope.

  Returns a list of conflict flags, each containing:
  - :type - "overlap" or "contradiction"
  - :existing_memory_id - the conflicting memory
  - :reason - explanation
  - :confidence - :high, :medium, or :low
  """
  def check(memory_id, scope_path, tags) when is_binary(scope_path) and is_list(tags) do
    scope_memories =
      Acs.Memory.Search.list(
        scope_path: scope_path,
        status: "approved"
      )

    scope_memories
    |> Enum.reject(fn m -> m.id == memory_id end)
    |> Enum.reduce([], fn existing, flags ->
      existing_tags = parse_tags(existing.tags_json)

      overlapping =
        MapSet.intersection(
          MapSet.new(tags),
          MapSet.new(existing_tags)
        )
        |> MapSet.size()

      if overlapping >= @tag_overlap_threshold do
        flag = %{
          type: "overlap",
          existing_memory_id: existing.id,
          reason:
            "Proposed memory shares #{overlapping} tags with existing approved memory '#{existing.id}' at same scope",
          confidence: if(overlapping >= 4, do: :high, else: :medium)
        }

        [flag | flags]
      else
        flags
      end
    end)
  end

  def check(_memory_id, _scope_path, _tags), do: []

  @doc """
  Checks a proposed memory for conflicts using an already-fetched list
  of approved memories, avoiding additional database queries.

  Filters by scope path and excludes the memory itself from self-matching.
  """
  def check_in_memory(memory, tags, approved_memories)
      when is_list(tags) and is_list(approved_memories) do
    scope_path = memory.scope_path
    memory_id = memory.id

    approved_memories
    |> Enum.filter(fn m -> m.status == "approved" end)
    |> Enum.filter(fn m -> m.scope_path == scope_path end)
    |> Enum.reject(fn m -> m.id == memory_id end)
    |> Enum.reduce([], fn existing, flags ->
      existing_tags = parse_tags(existing.tags_json)

      overlapping =
        MapSet.intersection(
          MapSet.new(tags),
          MapSet.new(existing_tags)
        )
        |> MapSet.size()

      if overlapping >= @tag_overlap_threshold do
        flag = %{
          type: "overlap",
          existing_memory_id: existing.id,
          reason:
            "Proposed memory shares #{overlapping} tags with existing approved memory '#{existing.id}' at same scope",
          confidence: if(overlapping >= 4, do: :high, else: :medium)
        }

        [flag | flags]
      else
        flags
      end
    end)
  end

  def check_in_memory(_memory, _tags, _approved_memories), do: []

  @doc """
  Checks a memory for conflicts before saving.
  Returns {:ok, flags} where flags may be empty (no conflicts)
  or contain conflict warnings.
  """
  def check_before_save(memory_map) do
    id = memory_map["id"] || ""
    scope_path = memory_map["scope_path"] || ""
    tags = memory_map["tags"] || []

    flags = check(id, scope_path, tags)

    if flags == [] do
      {:ok, []}
    else
      {:ok, flags}
    end
  end

  defp parse_tags(nil), do: []

  defp parse_tags(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, tags} when is_list(tags) -> tags
      _ -> []
    end
  end

  defp parse_tags(_), do: []
end
