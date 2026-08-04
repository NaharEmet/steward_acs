defmodule Acs.UserTasks do
  @moduledoc """
  Per-user chat reminders on `acs_tasks` (`kind: "user"`).

  - Surfaced from `remind_at` via `pending_reminders/2` (injected into chat `get_started`).
  - Query: assignee + same/higher clearance (`viewer_order <= task.authority_sort_order`).
  - Create-for-others: strictly higher clearance only.
  - Outcomes: done | dismiss | remind_later (remind_later requires explicit `remind_at`).
  """

  import Ecto.Query, warn: false

  alias Acs.Acs.Task, as: AcsTask
  alias Acs.AuthorityLevels
  alias Acs.Memory.Retry
  alias Acs.Org
  alias Acs.PersonStatus
  alias Acs.Repo

  @doc "Open user tasks for `assignee` with remind_at <= now."
  def pending_reminders(assignee, org \\ nil)
      when is_binary(assignee) do
    org = org || Org.current()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    name = String.trim(assignee)

    from(t in AcsTask,
      where: t.org == ^org,
      where: t.kind == "user",
      where: t.assignee == ^name,
      where: t.status == "todo",
      where: not is_nil(t.remind_at) and t.remind_at <= ^now,
      order_by: [asc: t.remind_at, asc: t.due_at]
    )
    |> Repo.all()
    |> Enum.map(&to_map/1)
  end

  @doc """
  Create a user task.

  Requires `due_at` and `remind_at`. Assigning someone else needs strictly higher
  clearance than the assignee.
  """
  def create(attrs, actor, opts \\ []) when is_map(attrs) and is_binary(actor) do
    org = Keyword.get(opts, :org) || Org.current()
    viewer_order = Keyword.get(opts, :viewer_sort_order) || AuthorityLevels.lowest(org).sort_order
    actor = String.trim(actor)

    with {:ok, due_at} <- require_datetime(attrs, "due_at"),
         {:ok, remind_at} <- require_datetime(attrs, "remind_at"),
         :ok <- validate_remind_before_or_at_due(remind_at, due_at),
         assignee <- resolve_assignee(attrs, actor),
         :ok <- authorize_assign(actor, assignee, viewer_order, org) do
      assignee_order = assignee_sort_order(org, assignee)

      task_attrs = %{
        "title" => attrs["title"] || attrs[:title],
        "slug" => Acs.unique_slug(attrs["title"] || attrs[:title] || "", org),
        "description" => attrs["description"] || attrs[:description] || "",
        "kind" => "user",
        "status" => "todo",
        "assignee" => assignee,
        "due_at" => due_at,
        "remind_at" => remind_at,
        "authority_sort_order" => assignee_order,
        "created_by_agent" => actor,
        "org" => org,
        "file_paths" => []
      }

      case Retry.with_busy_retry(fn ->
             %AcsTask{} |> AcsTask.changeset(task_attrs) |> Repo.insert()
           end) do
        {:ok, task} -> {:ok, to_map(task)}
        {:error, %Ecto.Changeset{} = cs} -> {:error, format_changeset(cs)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  List user tasks visible to the viewer.

  Defaults to the viewer's own tasks. `for_user` queries another person (same/higher
  clearance required).
  """
  def list(viewer, opts \\ []) when is_binary(viewer) do
    org = Keyword.get(opts, :org) || Org.current()
    viewer_order = Keyword.get(opts, :viewer_sort_order) || AuthorityLevels.lowest(org).sort_order
    viewer = String.trim(viewer)
    for_user = opts |> Keyword.get(:for_user) |> blank_to_nil()
    status = opts |> Keyword.get(:status) |> blank_to_nil()

    target = for_user || viewer

    with :ok <- authorize_query(viewer, target, viewer_order, org) do
      query =
        from(t in AcsTask,
          where: t.org == ^org,
          where: t.kind == "user",
          where: t.assignee == ^target,
          order_by: [asc: t.remind_at, desc: t.inserted_at]
        )

      query =
        case status do
          nil -> from(t in query, where: t.status in ^AcsTask.user_statuses())
          "open" -> from(t in query, where: t.status == "todo")
          s -> from(t in query, where: t.status == ^s)
        end

      {:ok, Repo.all(query) |> Enum.map(&to_map/1)}
    end
  end

  @doc """
  Resolve a user task: `done` | `dismiss` | `remind_later`.

  `remind_later` requires `remind_at` in opts/attrs — no default offset.
  """
  def resolve(task_id, actor, outcome, opts \\ [])
      when is_binary(task_id) and is_binary(actor) and is_binary(outcome) do
    org = Keyword.get(opts, :org) || Org.current()
    viewer_order = Keyword.get(opts, :viewer_sort_order) || AuthorityLevels.lowest(org).sort_order
    actor = String.trim(actor)
    outcome = String.trim(outcome) |> String.downcase()

    case find_user_task(task_id, org) do
      nil ->
        {:error, "task not found"}

      %AcsTask{kind: kind} when kind != "user" ->
        {:error, "not a user task — use release_work for coordination tasks"}

      %AcsTask{} = task ->
        with :ok <- authorize_resolve(actor, task, viewer_order),
             {:ok, changes} <- outcome_changes(outcome, opts) do
          case task |> AcsTask.changeset(changes) |> Repo.update() do
            {:ok, updated} -> {:ok, to_map(updated)}
            {:error, %Ecto.Changeset{} = cs} -> {:error, format_changeset(cs)}
          end
        end
    end
  end

  def user_task_args?(args) when is_map(args) do
    kind = args["kind"] || args[:kind]

    kind == "user" or present?(args["due_at"]) or present?(args["remind_at"]) or
      present?(args["assignee"])
  end

  def user_task_args?(_), do: false

  # --- resolution ---

  defp find_user_task(task_ref, org) when is_binary(task_ref) do
    if uuid?(task_ref) do
      Repo.one(from(t in AcsTask, where: t.id == ^task_ref and t.org == ^org))
    else
      Repo.one(from(t in AcsTask, where: t.slug == ^task_ref and t.org == ^org))
    end
  end

  @uuid_re ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

  defp uuid?(ref) when is_binary(ref), do: Regex.match?(@uuid_re, ref)
  defp uuid?(_), do: false

  # --- auth ---

  defp authorize_assign(actor, assignee, viewer_order, org) do
    if same_person?(actor, assignee) do
      :ok
    else
      assignee_order = assignee_sort_order(org, assignee)

      # Strictly higher clearance: lower sort_order number
      if is_integer(viewer_order) and is_integer(assignee_order) and viewer_order < assignee_order do
        :ok
      else
        {:error,
         "can only assign user tasks to people with lower clearance than you (not peers or higher)"}
      end
    end
  end

  defp authorize_query(viewer, target, viewer_order, org) do
    if same_person?(viewer, target) do
      :ok
    else
      target_order = assignee_sort_order(org, target)

      if is_integer(viewer_order) and is_integer(target_order) and viewer_order <= target_order do
        :ok
      else
        {:error, "not allowed to list user tasks for #{target} (need same or higher clearance)"}
      end
    end
  end

  defp authorize_resolve(actor, %AcsTask{} = task, viewer_order) do
    if same_person?(actor, task.assignee) do
      :ok
    else
      task_order = task.authority_sort_order

      if is_integer(viewer_order) and is_integer(task_order) and viewer_order < task_order do
        :ok
      else
        {:error, "only the assignee or a higher-clearance manager can resolve this task"}
      end
    end
  end

  defp assignee_sort_order(org, name) when is_binary(name) do
    case PersonStatus.get(org, name: name) do
      %{rank: rank} when is_binary(rank) ->
        AuthorityLevels.sort_order_for(org, rank) || AuthorityLevels.lowest(org).sort_order

      _ ->
        AuthorityLevels.lowest(org).sort_order
    end
  end

  # --- outcomes ---

  defp outcome_changes("done", _opts), do: {:ok, %{"status" => "done"}}
  defp outcome_changes("dismiss", _opts), do: {:ok, %{"status" => "dismissed"}}

  defp outcome_changes("remind_later", opts) do
    case require_datetime(Map.new(opts), "remind_at") do
      {:ok, remind_at} ->
        {:ok, %{"status" => "todo", "remind_at" => remind_at}}

      {:error, _} ->
        {:error,
         "remind later needs a new remind_at — pass when to surface this again (ISO-8601)"}
    end
  end

  defp outcome_changes(other, _opts) do
    {:error, "outcome must be done, dismiss, or remind_later (got: #{inspect(other)})"}
  end

  # --- parsing / helpers ---

  defp require_datetime(attrs, key) when is_map(attrs) do
    raw = attrs[key] || attrs[String.to_atom(key)]

    case parse_datetime(raw) do
      %DateTime{} = dt ->
        {:ok, dt}

      nil ->
        {:error, "user tasks require #{key} (ISO-8601 datetime) — pass a time, do not invent one"}
    end
  end

  defp parse_datetime(%DateTime{} = dt), do: DateTime.truncate(dt, :second)

  defp parse_datetime(str) when is_binary(str) do
    trimmed = String.trim(str)

    case DateTime.from_iso8601(trimmed) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp validate_remind_before_or_at_due(remind_at, due_at) do
    if DateTime.compare(remind_at, due_at) in [:lt, :eq] do
      :ok
    else
      {:error, "remind_at must be at or before due_at"}
    end
  end

  defp resolve_assignee(attrs, actor) do
    case blank_to_nil(attrs["assignee"] || attrs[:assignee]) do
      nil -> String.trim(actor)
      name -> String.trim(name)
    end
  end

  defp same_person?(a, b) when is_binary(a) and is_binary(b),
    do: String.downcase(String.trim(a)) == String.downcase(String.trim(b))

  defp same_person?(_, _), do: false

  defp present?(v) when is_binary(v), do: String.trim(v) != ""
  defp present?(%DateTime{}), do: true
  defp present?(_), do: false

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(s) when is_binary(s) do
    t = String.trim(s)
    if t == "", do: nil, else: t
  end

  defp blank_to_nil(other), do: other

  defp format_changeset(cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map(fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
    |> Enum.join("; ")
  end

  def to_map(%AcsTask{} = t) do
    %{
      id: t.id,
      slug: t.slug,
      title: t.title,
      description: t.description,
      status: t.status,
      kind: t.kind,
      assignee: t.assignee,
      due_at: t.due_at,
      remind_at: t.remind_at,
      authority_sort_order: t.authority_sort_order,
      created_by_agent: t.created_by_agent,
      org: t.org,
      inserted_at: t.inserted_at
    }
  end
end
