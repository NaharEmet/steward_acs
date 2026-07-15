defmodule Acs.Acs.Similarity do
  @moduledoc """
  Similarity detection for tasks.

  Uses two strategies:
  1. Name similarity (Levenshtein distance ≤ 3 or substring match)
  2. File overlap with existing in_progress tasks
  """

  alias Acs.Acs.Cache

  @name_distance_threshold 3

  def find_similar_tasks(title, file_paths) when is_list(file_paths) do
    try do
      org = Acs.Org.current()
      in_progress_tasks = Cache.get_tasks_by_status("in_progress", org)

      if Enum.empty?(in_progress_tasks) do
        []
      else
        similar_by_name = find_similar_by_name(title, in_progress_tasks)
        similar_by_files = find_similar_by_files(file_paths, org)

        (similar_by_name ++ similar_by_files)
        |> Enum.uniq_by(fn t -> t.id end)
      end
    rescue
      _e in _ ->
        []
    end
  end

  def find_similar_tasks(_title, _file_paths) do
    # Return empty when file_paths isn't usable - similarity check requires file_paths
    []
  end

  @doc """
  Checks if two strings are similar (Myers edit distance within threshold).
  """
  def similar_name?(name1, name2) do
    edit_dist =
      String.myers_difference(String.downcase(name1), String.downcase(name2))
      |> elem(1)
      |> Enum.reduce(0, fn
        {:del, s}, acc -> acc + String.length(s)
        {:ins, s}, acc -> acc + String.length(s)
        _, acc -> acc
      end)

    edit_dist <= @name_distance_threshold
  end

  @doc """
  Checks if one string is a substring of the other (case insensitive).
  """
  def substring_match?(str1, str2) do
    s1 = String.downcase(str1)
    s2 = String.downcase(str2)
    String.contains?(s1, s2) or String.contains?(s2, s1)
  end

  defp find_similar_by_name(title, tasks) when is_binary(title) do
    Enum.filter(tasks, fn task ->
      similar_name?(title, task.title) or
        substring_match?(title, task.title)
    end)
  end

  defp find_similar_by_files(file_paths, org) when is_list(file_paths) do
    all_tasks = Cache.get_tasks_by_status("in_progress", org)

    Enum.filter(all_tasks, fn task ->
      if task.status == "in_progress" && task.id do
        task_locks = Cache.get_file_locks_for_task(task.id, org)
        task_files = Enum.map(task_locks, fn l -> l.file_path end)

        Enum.any?(file_paths, fn fp ->
          Enum.any?(task_files, fn tf -> paths_overlap?(fp, tf) end)
        end)
      else
        false
      end
    end)
  end

  defp paths_overlap?(path1, path2) do
    path1 == path2 or
      String.starts_with?(path1, path2) or
      String.starts_with?(path2, path1)
  end
end
