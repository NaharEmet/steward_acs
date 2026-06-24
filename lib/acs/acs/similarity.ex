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
      in_progress_tasks = Cache.get_tasks_by_status("in_progress")

      if Enum.empty?(in_progress_tasks) do
        []
      else
        similar_by_name = find_similar_by_name(title, in_progress_tasks)
        similar_by_files = find_similar_by_files(file_paths)

        (similar_by_name ++ similar_by_files)
        |> Enum.uniq_by(fn t -> t.id end)
      end
    rescue
      _e in _ ->
        # Cache not available - return empty
        []
    end
  end

  def find_similar_tasks(_title, _file_paths) do
    # Return empty when file_paths isn't usable - similarity check requires file_paths
    []
  end

  @doc """
  Levenshtein distance between two strings.
  """
  def levenshtein("", ""), do: 0
  def levenshtein(string, ""), do: String.length(string)
  def levenshtein("", string), do: String.length(string)

  def levenshtein(string1, string2) do
    s1 = String.to_charlist(String.downcase(string1))
    s2 = String.to_charlist(String.downcase(string2))
    levenshtein_impl(s1, s2, length(s1), length(s2))
  end

  defp levenshtein_impl(s1, s2, len1, len2) do
    # Initialize first row and column
    row0 = Enum.to_list(0..len2)
    matrix = [row0 | for(_ <- 1..len1, do: [0 | List.duplicate(0, len2)])]

    Enum.reduce(1..len1, matrix, fn i, matrix ->
      prev_row = Enum.at(matrix, i - 1)

      Enum.reduce(1..len2, {matrix, 0}, fn j, {matrix, last_val} ->
        cost = if Enum.at(s1, i - 1) == Enum.at(s2, j - 1), do: 0, else: 1
        del = Enum.at(prev_row, j) + 1
        ins = last_val + 1
        sub = Enum.at(prev_row, j - 1) + cost
        min_val = Enum.min([del, ins, sub])
        cur_row = Enum.at(matrix, i)
        new_row = List.update_at(cur_row, j, fn _ -> min_val end)
        matrix = List.replace_at(matrix, i, new_row)
        {matrix, min_val}
      end)
      |> elem(0)
    end)
    |> Enum.at(len1)
    |> Enum.at(len2)
  end

  @doc """
  Checks if two strings are similar (Levenshtein distance within threshold).
  """
  def similar_name?(name1, name2) do
    levenshtein(String.downcase(name1), String.downcase(name2)) <= @name_distance_threshold
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

  defp find_similar_by_files(file_paths) when is_list(file_paths) do
    all_tasks = Cache.get_all_tasks()

    Enum.filter(all_tasks, fn task ->
      if task.status == "in_progress" && task.id do
        task_locks = Cache.get_file_locks_for_task(task.id)
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