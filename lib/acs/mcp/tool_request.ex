defmodule Acs.MCP.ToolRequest do
  @moduledoc """
  Ecto schema for tracking agent tool requests.

  When an agent requests a new tool via the `request_tool` MCP method,
  a ToolRequest record is created. A human operator can then approve
  or reject it via the ACS dashboard.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "tool_requests" do
    field :name, :string
    field :description, :string
    field :category, :string, default: "requested"
    # JSON-encoded tool definition
    field :definition, :string
    # pending | approved | rejected
    field :status, :string, default: "pending"
    field :agent_id, :string
    field :approved_by, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(request, attrs) do
    request
    |> cast(attrs, [:name, :description, :category, :definition, :status, :agent_id, :approved_by])
    |> validate_required([:name, :definition, :agent_id])
    |> validate_inclusion(:status, ["pending", "approved", "rejected"])
    |> unique_constraint(:name, name: :tool_requests_name_index)
  end

  @doc """
  Encodes a tool definition map to JSON string for storage.
  """
  def encode_definition(definition) when is_map(definition) do
    Jason.encode!(definition)
  end

  @doc """
  Decodes a stored JSON definition back to a map.
  """
  def decode_definition(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} -> decoded
      _ -> %{}
    end
  end
end
