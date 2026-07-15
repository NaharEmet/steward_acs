defmodule Acs.MCP.ToolRequests do
  @moduledoc """
  Context module for managing agent tool requests.

  Agents request new MCP tools via the `request_tool` MCP method.
  These requests are stored in the database with a pending status.
  A human operator approves or rejects them via the ACS dashboard.
  """

  import Ecto.Query, only: [from: 2]
  alias Acs.MCP.ToolRequest
  alias Acs.Repo

  @doc """
  Creates a new tool request from an agent's definition.

  Returns `{:ok, %ToolRequest{}}` on success, or `{:error, changeset}`.
  """
  def create_request(agent_id, definition) when is_map(definition) do
    %ToolRequest{}
    |> ToolRequest.changeset(%{
      name: definition["name"] || "unnamed",
      description: definition["description"] || "",
      category: definition["category"] || "requested",
      definition: ToolRequest.encode_definition(definition),
      status: "pending",
      agent_id: agent_id,
      org: Acs.Org.current()
    })
    |> Repo.insert()
  end

  @doc """
  Lists all tool requests, optionally filtered by status.
  """
  def list_requests(status \\ nil, org \\ Acs.Org.current()) do
    query =
      from r in ToolRequest,
        where: r.org == ^org,
        order_by: [desc: r.inserted_at]

    query =
      case status do
        nil -> query
        s -> from r in query, where: r.status == ^s
      end

    Repo.all(query)
  end

  @doc """
  Gets a single tool request by ID.
  """
  def get_request(id, org \\ Acs.Org.current()) do
    Repo.get_by(ToolRequest, id: id, org: org)
  end

  @doc """
  Approves a pending tool request.

  The tool definition is decoded and made available through ToolRegistry.
  Returns `{:ok, request}` on success.
  """
  def approve_request(id, approved_by) do
    case get_request(id) do
      nil ->
        {:error, "Request not found"}

      request ->
        request
        |> ToolRequest.changeset(%{status: "approved", approved_by: approved_by})
        |> Repo.update()
    end
  end

  @doc """
  Rejects a pending tool request.
  """
  def reject_request(id, approved_by) do
    case get_request(id) do
      nil ->
        {:error, "Request not found"}

      request ->
        request
        |> ToolRequest.changeset(%{status: "rejected", approved_by: approved_by})
        |> Repo.update()
    end
  end

  @doc """
  Returns pending request count (useful for dashboard badges).
  """
  def pending_count(org \\ Acs.Org.current()) do
    Repo.aggregate(
      from(r in ToolRequest, where: r.status == "pending" and r.org == ^org),
      :count,
      :id
    )
  end
end
