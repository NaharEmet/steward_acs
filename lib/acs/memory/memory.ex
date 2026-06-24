defmodule Acs.Memory do
  @moduledoc """
  Represents a single ACS Memory entry.

  Memories are stored as YAML files in priv/acs_memory/ organized
  by application/component scope. This struct handles parsing,
  validation, and serialization.
  """

  @kind_types ~w(observation learning warning pattern bug decision invariant axiom)
  @status_types ~w(proposed approved rejected stale deprecated archived parse_error)
  @valid_verification_statuses ~w(proposed approved rejected)

  @slug_cleanup_regex ~r/[^a-z0-9]+/

  defstruct [
    :id, :kind, :status, :title, :summary, :content,
    :scope_path, :importance, :tags, :triggers, :failure_modes,
    :related_memories, :verification, :revalidation, :created_by,
    :created_at, :updated_at
  ]

  @type t :: %__MODULE__{
    id: String.t(),
    kind: String.t(),
    status: String.t(),
    title: String.t(),
    summary: String.t() | nil,  # intentionally optional — not validated
    content: String.t(),
    scope_path: String.t(),
    importance: non_neg_integer(),
    tags: [String.t()],
    triggers: [String.t()],
    failure_modes: [String.t()],
    related_memories: [String.t()],
    verification: map(),
    revalidation: map(),
    created_by: map(),
    created_at: String.t(),
    updated_at: String.t()
  }

  @doc """
  Creates a new Memory struct from validated attributes.
  """
  def new(attrs \\ %{}) do
    struct(__MODULE__, %{
      id: attrs["id"] || generate_id(attrs),
      kind: attrs["kind"] || "observation",
      status: attrs["status"] || "proposed",
      title: attrs["title"] || "",
      summary: attrs["summary"],
      content: attrs["content"] || "",
      scope_path: attrs["scope_path"] || "",
      importance: attrs["importance"] || 3,
      tags: attrs["tags"] || [],
      triggers: attrs["triggers"] || [],
      failure_modes: attrs["failure_modes"] || [],
      related_memories: attrs["related_memories"] || [],
      verification: attrs["verification"] || %{
        "status" => "proposed",
        "approved_by" => nil,
        "approved_at" => nil
      },
      revalidation: attrs["revalidation"] || %{
        "interval_days" => 30,
        "last_checked_at" => nil
      },
      created_by: attrs["created_by"] || %{
        "type" => "agent",
        "id" => "unknown"
      },
      created_at: attrs["created_at"] || get_in(attrs, ["timestamps", "created_at"]) || DateTime.utc_now() |> DateTime.to_iso8601(),
      updated_at: attrs["updated_at"] || get_in(attrs, ["timestamps", "updated_at"]) || DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  @doc """
  Validates a Memory map. Returns :ok or {:error, reasons}.
  """
  def validate(memory_map) when is_map(memory_map) do
    errors = []

    errors = if is_nil(memory_map["id"]) or memory_map["id"] == "",
      do: ["Missing required field: id" | errors], else: errors

    errors = if is_nil(memory_map["kind"]) or memory_map["kind"] == "",
      do: ["Missing required field: kind" | errors], else: errors

    errors = if memory_map["kind"] && memory_map["kind"] != "" && memory_map["kind"] not in @kind_types,
      do: ["Invalid kind '#{memory_map["kind"]}'. Must be one of: #{Enum.join(@kind_types, ", ")}" | errors], else: errors

    errors = if memory_map["status"] == "",
      do: ["Missing required field: status" | errors], else: errors

    errors = if memory_map["status"] && memory_map["status"] != "" && memory_map["status"] not in @status_types,
      do: ["Invalid status '#{memory_map["status"]}'. Must be one of: #{Enum.join(@status_types, ", ")}" | errors], else: errors

    errors = if is_nil(memory_map["title"]) or memory_map["title"] == "",
      do: ["Missing required field: title" | errors], else: errors

    errors = if is_nil(memory_map["scope_path"]) or memory_map["scope_path"] == "",
      do: ["Missing required field: scope_path" | errors], else: errors

    errors = cond do
      is_nil(memory_map["importance"]) -> ["Missing required field: importance" | errors]
      !is_integer(memory_map["importance"]) -> ["importance must be an integer, got: #{inspect(memory_map["importance"])}" | errors]
      memory_map["importance"] < 1 or memory_map["importance"] > 5 -> ["importance must be between 1 and 5, got: #{memory_map["importance"]}" | errors]
      true -> errors
    end

    errors = if memory_map["verification"] && memory_map["verification"]["status"] &&
      memory_map["verification"]["status"] not in @valid_verification_statuses,
      do: ["Invalid verification status: #{memory_map["verification"]["status"]}" | errors], else: errors

    if errors == [], do: :ok, else: {:error, Enum.reverse(errors)}
  end

  def validate(_), do: {:error, ["Memory must be a map"]}

  @doc """
  Converts a Memory struct to a map suitable for YAML serialization.
  """
  def to_yaml_map(%__MODULE__{} = memory) do
    %{
      "id" => memory.id,
      "kind" => memory.kind,
      "status" => memory.status,
      "title" => memory.title,
      "scope_path" => memory.scope_path,
      "summary" => memory.summary,
      "content" => memory.content,
      "importance" => memory.importance,
      "tags" => memory.tags,
      "triggers" => memory.triggers,
      "failure_modes" => memory.failure_modes,
      "related_memories" => memory.related_memories,
      "verification" => memory.verification,
      "revalidation" => memory.revalidation,
      "created_by" => memory.created_by,
      "created_at" => memory.created_at,
      "updated_at" => memory.updated_at
    }
  end

  @doc """
  Derives scope_path from a file path.
  e.g., "priv/acs_memory/agent_coordination_system/cache/invalidation.yaml"
  → "agent_coordination_system/cache/invalidation"
  """
  def derive_scope_from_path(file_path) do
    path = file_path
      |> String.replace_prefix("priv/acs_memory/", "")
      |> String.replace_suffix(".yaml", "")
    path
  end

  @doc """
  Generates a deterministic memory ID from kind, title, and scope_path.
  """
  def generate_id(attrs) do
    kind = attrs["kind"] || "memory"
    title = attrs["title"] || "untitled"
    scope = attrs["scope_path"] || "global"

    title_slug = title
      |> String.downcase()
      |> String.replace(@slug_cleanup_regex, "_")
      |> String.trim("_")
      |> String.slice(0, 40)

    # Hash scope_path to get a short, consistent suffix
    scope_hash = :crypto.hash(:md5, scope) |> Base.encode16() |> String.slice(0, 8)

    "#{kind}_#{title_slug}_#{scope_hash}"
  end

  @doc false
  def kind_types, do: @kind_types
  @doc false
  def status_types, do: @status_types
end
