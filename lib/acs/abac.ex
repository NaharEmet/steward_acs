defmodule Acs.Abac do
  @moduledoc """
  Attribute-based access control for org knowledge and coding-agent documents.

  ## Use cases

  1. **Coding agents** — specs (\`Acs.Specs.Entry\`) scoped by team/project
     so agents only read and write specs for code they work on.

  2. **Org KB memories** — atomic knowledge scoped by team/project/visibility for
     organizational knowledge about specific teams or projects.

  ## Visibility model

  - `org` — visible to all authenticated agents (default)
  - `team` — visible when `team` is in the caller's allowed teams
  - `project` — visible when `project` is in the caller's allowed projects

  Collaborators/readers without team or project allowlists only see `org` content.
  """

  @restricted_roles ~w(collaborator reader)
  @valid_visibilities ~w(org team project)

  defstruct agent_role: nil, allowed_teams: [], allowed_projects: []

  @type t :: %__MODULE__{
          agent_role: String.t() | nil,
          allowed_teams: [String.t()],
          allowed_projects: [String.t()]
        }

  @doc "Build ABAC context from MCP tool args (injected by Protocol)."
  def from_args(args) when is_map(args) do
    %__MODULE__{
      agent_role: Map.get(args, "_auth_role"),
      allowed_teams: normalize_list(Map.get(args, "_auth_allowed_teams")),
      allowed_projects: normalize_list(Map.get(args, "_auth_allowed_projects"))
    }
  end

  @doc "Build ABAC context from keyword opts (Indexer, Guidance, etc.)."
  def from_keyword(opts) when is_list(opts) do
    %__MODULE__{
      agent_role: Keyword.get(opts, :agent_role),
      allowed_teams: normalize_list(Keyword.get(opts, :allowed_teams)),
      allowed_projects: normalize_list(Keyword.get(opts, :allowed_projects))
    }
  end

  @doc "Returns true when the item is readable under the given context."
  def visible?(%__MODULE__{} = ctx, item), do: visible_item?(item, ctx)

  @doc "Filters a list to items visible under the given context."
  def filter(items, %__MODULE__{} = ctx) when is_list(items) do
    Enum.filter(items, &visible_item?(&1, ctx))
  end

  @doc """
  Validates write attributes (`visibility`, `team`, `project`).

  Returns `:ok` or `{:error, reason}`.
  """
  def validate_write(%__MODULE__{} = ctx, attrs) when is_map(attrs) do
    visibility = field(attrs, "visibility", "org")
    team = field(attrs, "team")
    project = field(attrs, "project")

    with :ok <- validate_visibility_value(visibility),
         :ok <- validate_scope_fields(visibility, team, project),
         :ok <- validate_write_scope(ctx, visibility, team, project) do
      :ok
    end
  end

  @doc """
  For restricted roles writing org-visible content, force `proposed` status so
  org-wide knowledge is reviewed before becoming searchable as approved.
  """
  def memory_status_for_write(%__MODULE__{} = ctx, attrs) when is_map(attrs) do
    visibility = field(attrs, "visibility", "org")

    if restricted_role?(ctx) and visibility == "org" do
      "proposed"
    else
      nil
    end
  end

  defp admin_role?(%__MODULE__{} = ctx), do: not restricted_role?(ctx)

  defp restricted_role?(%__MODULE__{agent_role: role}) when role in @restricted_roles, do: true
  defp restricted_role?(_), do: false

  defp has_teams?(%__MODULE__{allowed_teams: teams}), do: teams != []
  defp has_projects?(%__MODULE__{allowed_projects: projects}), do: projects != []

  defp visible_item?(item, ctx) do
    visibility = field(item, "visibility", "org")
    team = field(item, "team")
    project = field(item, "project")

    cond do
      admin_role?(ctx) ->
        true

      has_teams?(ctx) and has_projects?(ctx) ->
        visibility == "org" or
          (visibility == "team" and team in ctx.allowed_teams) or
          (visibility == "project" and project in ctx.allowed_projects)

      has_teams?(ctx) ->
        visibility == "org" or (visibility == "team" and team in ctx.allowed_teams)

      has_projects?(ctx) ->
        visibility == "org" or (visibility == "project" and project in ctx.allowed_projects)

      restricted_role?(ctx) ->
        visibility == "org"

      true ->
        true
    end
  end

  defp validate_write_scope(_ctx, "org", _team, _project), do: :ok

  defp validate_write_scope(ctx, "team", team, _project) do
    cond do
      admin_role?(ctx) ->
        :ok

      has_teams?(ctx) and team in ctx.allowed_teams ->
        :ok

      true ->
        {:error, "Not authorized to write team-scoped content for team '#{team}'"}
    end
  end

  defp validate_write_scope(ctx, "project", _team, project) do
    cond do
      admin_role?(ctx) ->
        :ok

      has_projects?(ctx) and project in ctx.allowed_projects ->
        :ok

      true ->
        {:error, "Not authorized to write project-scoped content for project '#{project}'"}
    end
  end

  defp validate_visibility_value(visibility) when visibility in @valid_visibilities, do: :ok

  defp validate_visibility_value(visibility),
    do: {:error, "Invalid visibility '#{visibility}'. Must be one of: org, team, project"}

  defp validate_scope_fields("team", team, _project) when is_binary(team) and team != "",
    do: :ok

  defp validate_scope_fields("team", _team, _project),
    do: {:error, "team visibility requires a non-empty team"}

  defp validate_scope_fields("project", _team, project) when is_binary(project) and project != "",
    do: :ok

  defp validate_scope_fields("project", _team, _project),
    do: {:error, "project visibility requires a non-empty project"}

  defp validate_scope_fields(_visibility, _team, _project), do: :ok

  defp field(item, key, default \\ nil)

  defp field(%_{} = struct, key, default) do
    atom_key = String.to_existing_atom(key)
    Map.get(struct, atom_key, default)
  rescue
    ArgumentError -> default
  end

  defp field(item, key, default) when is_map(item) do
    Map.get(item, key) || Map.get(item, String.to_existing_atom(key)) || default
  rescue
    ArgumentError -> Map.get(item, key, default)
  end

  defp normalize_list(nil), do: []
  defp normalize_list(list) when is_list(list), do: list
  defp normalize_list(_), do: []
end
