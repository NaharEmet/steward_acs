defmodule Acs.MCP.Tools.ErrorHandlers do
  @moduledoc """
  Handles error-management MCP tools: feedback, error traces, and tasks.

  ## Purpose

  Implements handler functions for submitting task feedback (which
  auto-generates knowledge memories), listing/acknowledging/resolving
  error traces, and creating investigation tasks from error patterns.

  ## Key Functions

  - `acs_submit_task_feedback/1` — Submits task feedback and generates
    knowledge memories from learnings, issues, and suggestions
  - `list_error_traces/1` — Lists error traces with optional filters
    (status, service, component, count)
  - `ack_error_trace/1` — Acknowledges an error trace for investigation
  - `resolve_error_trace/1` — Marks an error trace as resolved
  - `create_task_from_error_trace/1` — Creates an ACS task from an error
    trace for investigation
  """
  alias Acs.Acs.TaskCompletionFeedback, as: FeedbackSchema

  require Logger

  def acs_submit_task_feedback(args) do
    agent_id = args["agent_id"]
    task_id = args["task_id"]

    changeset =
      %FeedbackSchema{}
      |> FeedbackSchema.changeset(%{
        task_id: task_id,
        agent_id: agent_id,
        learned_for_agents: args["learned_for_agents"],
        had_issues: args["had_issues"],
        improvements: args["improvements"],
        tools_wish_list: args["tools_wish_list"],
        info_needed: args["info_needed"],
        guidance_useful: args["guidance_useful"],
        guidance_items_helpful: encode_array_field(args["guidance_items_helpful"]),
        guidance_items_confusing: encode_array_field(args["guidance_items_confusing"]),
        guidance_missing: args["guidance_missing"]
      })

    case Acs.Repo.insert(changeset) do
      {:ok, feedback} ->
        generate_memories_from_feedback(feedback, args)

        {:ok,
         %{feedback_id: feedback.id, message: "Task complete. Feedback submitted — you're done."}}

      {:error, reason} ->
        {:error, "Failed to submit feedback: #{inspect(reason)}"}
    end
  end

  @doc """
  Lists error traces with optional filters.
  """
  def list_error_traces(args) do
    Logger.info("[ErrorHandlers] list_error_traces with args: #{inspect(args)}")

    opts =
      []
      |> maybe_put_option(:status, args["status"])
      |> maybe_put_option(:service, args["service"])
      |> maybe_put_option(:component, args["component"])
      |> maybe_put_option(:min_count, args["min_count"])
      |> maybe_put_option(:limit, args["limit"])

    traces = Acs.MCP.ErrorTrace.list_traces(opts)

    formatted =
      Enum.map(traces, fn t ->
        %{
          id: t.id,
          timestamp: t.timestamp,
          service: t.service,
          component: t.component,
          message_pattern: t.message_pattern,
          sample_message: t.sample_message,
          count: t.count,
          status: t.status,
          task_id: t.task_id,
          level: t.level,
          last_seen_at: t.last_seen_at
        }
      end)

    {:ok, %{traces: formatted, total: length(formatted)}}
  end

  @doc """
  Acknowledges an error trace (sets status to acknowledged).
  """
  def ack_error_trace(args) do
    trace_id = args["trace_id"]

    if is_nil(trace_id) do
      {:error, "trace_id is required"}
    else
      Logger.info("[ErrorHandlers] ack_error_trace: #{trace_id}")

      case Acs.MCP.ErrorTrace.acknowledge_trace(trace_id) do
        {:ok, trace} ->
          {:ok, %{trace_id: trace.id, status: trace.status, message: "Trace acknowledged"}}

        {:error, reason} ->
          {:error, "Failed to acknowledge trace: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Resolves an error trace (sets status to resolved).
  """
  def resolve_error_trace(args) do
    trace_id = args["trace_id"]

    if is_nil(trace_id) do
      {:error, "trace_id is required"}
    else
      Logger.info("[ErrorHandlers] resolve_error_trace: #{trace_id}")

      case Acs.MCP.ErrorTrace.resolve_trace(trace_id) do
        {:ok, trace} ->
          {:ok, %{trace_id: trace.id, status: trace.status, message: "Trace resolved"}}

        {:error, reason} ->
          {:error, "Failed to resolve trace: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Creates an ACS task from an error trace and marks the trace as tasked.
  """
  def create_task_from_error_trace(args) do
    trace_id = args["trace_id"]
    agent_id = args["agent_id"] || "error_trace_system"

    if is_nil(trace_id) do
      {:error, "trace_id is required"}
    else
      Logger.info(
        "[ErrorHandlers] create_task_from_error_trace: #{trace_id} for agent #{agent_id}"
      )

      case Acs.MCP.ErrorTrace.get_trace(trace_id) do
        nil ->
          {:error, "Error trace not found: #{trace_id}"}

        trace ->
          task_title =
            "Error: #{trace.service}/#{trace.component} - #{String.slice(trace.message_pattern, 0, 80)}"

          task_description =
            "Error pattern: #{trace.message_pattern}\n\n" <>
              "Service: #{trace.service}\n" <>
              "Component: #{trace.component}\n" <>
              "Occurrences: #{trace.count}\n" <>
              "Last seen: #{DateTime.to_iso8601(trace.last_seen_at)}\n" <>
              "Sample: #{trace.sample_message || "N/A"}"

          attrs = %{
            "title" => task_title,
            "description" => task_description,
            "file_paths" => []
          }

          case Acs.create_task(attrs, agent_id) do
            {:ok, task} ->
              Acs.MCP.ErrorTrace.mark_tasked(trace_id, task.id)
              {:ok, %{task_id: task.id, trace_id: trace_id, status: "tasked"}}

            {:warn, task, similar} ->
              Acs.MCP.ErrorTrace.mark_tasked(trace_id, task.id)

              {:ok,
               %{task_id: task.id, trace_id: trace_id, status: "tasked", similar_tasks: similar}}

            {:error, reason} ->
              Acs.MCP.ErrorTrace.mark_failed(trace_id, inspect(reason))
              {:error, "Failed to create task: #{inspect(reason)}"}
          end
      end
    end
  end

  defp encode_array_field(nil), do: nil
  defp encode_array_field([]), do: Jason.encode!([])
  defp encode_array_field(list) when is_list(list), do: Jason.encode!(list)
  defp encode_array_field(value), do: value

  defp generate_memories_from_feedback(feedback, args) do
    scope_path = derive_scope_from_task(args["task_id"]) || "agent_coordination_system/feedback"

    if learned = args["learned_for_agents"] do
      save_feedback_memory(
        "learning",
        "Key learning from task #{String.slice(args["task_id"] || "", 0, 8)}",
        learned,
        scope_path
      )
    end

    if had_issues = args["had_issues"] do
      save_feedback_memory(
        "warning",
        "Issue encountered in task #{String.slice(args["task_id"] || "", 0, 8)}",
        had_issues,
        scope_path
      )
    end

    if improvements = args["improvements"] do
      save_feedback_memory(
        "learning",
        "Improvement suggestion from task feedback",
        improvements,
        scope_path
      )
    end

    if tools_wish_list = args["tools_wish_list"] do
      save_feedback_memory(
        "pattern",
        "Tool request from agent feedback",
        tools_wish_list,
        scope_path
      )
    end

    if info_needed = args["info_needed"] do
      save_feedback_memory(
        "observation",
        "Information gap identified in task",
        info_needed,
        scope_path
      )
    end

    if guidance_useful = feedback.guidance_useful do
      save_feedback_memory(
        "observation",
        "Guidance rated as #{if guidance_useful == true, do: "useful", else: "not useful"}",
        "Agent rated guidance #{if guidance_useful == true, do: "as helpful", else: "as not helpful"} for this task",
        scope_path
      )
    end

    if (helpful_items = args["guidance_items_helpful"]) && is_list(helpful_items) &&
         helpful_items != [] do
      save_feedback_memory(
        "learning",
        "Guidance items that helped",
        "Helpful items: #{Enum.join(helpful_items, ", ")}",
        scope_path
      )
    end

    if (confusing_items = args["guidance_items_confusing"]) && is_list(confusing_items) &&
         confusing_items != [] do
      save_feedback_memory(
        "warning",
        "Guidance items that were confusing or unhelpful",
        "Confusing items: #{Enum.join(confusing_items, ", ")}",
        scope_path
      )
    end

    if guidance_missing = args["guidance_missing"] do
      save_feedback_memory(
        "observation",
        "Guidance gap identified",
        guidance_missing,
        scope_path
      )
    end
  end

  defp save_feedback_memory(kind, title, content, scope_path) do
    org = Acs.Org.current()

    memory_map = %{
      "id" => Acs.Memory.generate_id(%{"kind" => kind, "title" => title}),
      "kind" => kind,
      "status" => "proposed",
      "title" => title,
      "summary" => String.slice(content, 0, 200),
      "content" => content,
      "scope_path" => scope_path,
      "importance" => 3,
      "tags" => ["feedback", kind],
      "triggers" => [],
      "failure_modes" => [],
      "created_by" => %{
        "type" => "developer",
        "id" => Acs.Cluster.developer_name(),
        "org" => org
      },
      "org" => org
    }

    case Acs.Memory.validate(memory_map) do
      :ok ->
        memory = Acs.Memory.new(memory_map)

        with :ok <- Acs.Memory.Loader.save(memory),
             {:ok, _} <- Acs.Memory.Indexer.upsert_memory(memory) do
          :ok
        else
          {:error, reason} ->
            Logger.warning(
              "[Tools] Feedback memory save failed for '#{title}': #{inspect(reason)}"
            )

            :ok
        end

      {:error, reasons} ->
        Logger.warning(
          "[Tools] Feedback memory validation failed for '#{title}': #{Enum.join(reasons, "; ")}"
        )

        :ok
    end
  end

  defp derive_scope_from_task(task_id) when is_binary(task_id) do
    case Acs.Acs.get_task(task_id) do
      %{file_paths: [first | _]} when is_binary(first) ->
        derive_scope_from_path(first)

      _ ->
        nil
    end
  end

  defp derive_scope_from_task(_), do: nil

  defp derive_scope_from_path(path) when is_binary(path) do
    path
    |> String.trim_leading("apps/")
    |> String.trim_leading("lib/")
    |> String.replace(~r{/[\w\-]+\.\w+$}, "")
    |> String.replace("/", ".")
  end

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)
end
