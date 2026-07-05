defmodule Acs.Specs.Search do
  @moduledoc """
  Full-text search across cognition spec entries.

  Provides simple in-memory substring matching over loaded spec entries.
  Scoring is based on which fields match the query terms, with title
  matches weighted highest and constraint matches weighted lowest.
  """

  alias Acs.Specs.Loader

  @max_results 20

  @doc """
  Search across all loaded spec entries. Returns `{:ok, [%Entry{}]}`.

  ## Options
    * `:app` — Filter by app (string or nil)
    * `:status` — Filter by status (string or nil)
    * `:limit` — Max results (default: 20)
  """
  def search(query, opts \\ [])

  def search(nil, _opts), do: {:ok, []}
  def search("", _opts), do: {:ok, []}

  def search(query, opts) do
    app = opts[:app]
    status_filter = opts[:status]
    limit = opts[:limit] || @max_results
    query_words = tokenize(query)

    with {:ok, entries} <- Loader.load_all(app: app) do
      results =
        entries
        |> Enum.map(fn entry ->
          score = score_entry(entry, query_words)
          %{entry: entry, score: score}
        end)
        |> Enum.reject(fn %{score: score} -> score == 0 end)
        |> Enum.sort_by(fn %{score: score} -> score end, :desc)
        |> maybe_filter_by_status(status_filter)
        |> Enum.take(limit)
        |> Enum.map(fn %{entry: entry} -> entry end)

      {:ok, results}
    end
  end

  # Tokenize a query string into lowercase words.
  defp tokenize(query) do
    query
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
  end

  # Score a single entry against query words.
  # Higher scores for title and purpose matches; lower for constraints and failure modes.
  defp score_entry(entry, query_words) do
    title = (entry.title || "") |> String.downcase()
    purpose = (entry.purpose || "") |> String.downcase()
    tags = (entry.tags || []) |> Enum.map(&String.downcase/1)
    invariants = (entry.invariants || []) |> Enum.map(&normalize_to_string/1)
    workflows = (entry.workflows || []) |> Enum.map(&normalize_to_string/1)
    failure_modes = (entry.failure_modes || []) |> Enum.map(&normalize_to_string/1)
    constraints = (entry.constraints || []) |> Enum.map(&normalize_to_string/1)

    Enum.reduce(query_words, 0, fn word, acc ->
      acc +
        if(String.contains?(title, word), do: 10, else: 0) +
        if(String.contains?(purpose, word), do: 8, else: 0) +
        Enum.count(tags, &(&1 == word)) * 5 +
        Enum.count(invariants, &String.contains?(&1, word)) * 3 +
        Enum.count(workflows, &String.contains?(&1, word)) * 3 +
        Enum.count(failure_modes, &String.contains?(&1, word)) * 2 +
        Enum.count(constraints, &String.contains?(&1, word)) * 2
    end)
  end

  # Convert any value to a downcased string for scoring.
  # Strings are downcased directly.
  # Maps are flattened to "key: value, key2: value2" format.
  # All other values are converted via to_string/1.
  defp normalize_to_string(value) when is_binary(value), do: String.downcase(value)

  defp normalize_to_string(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> "#{k}: #{v}" end)
    |> Enum.join(", ")
    |> String.downcase()
  end

  defp normalize_to_string(value), do: value |> to_string() |> String.downcase()

  # Filter results by status. Returns all results when status is nil.
  defp maybe_filter_by_status(results, nil), do: results

  defp maybe_filter_by_status(results, status) do
    Enum.filter(results, fn %{entry: entry} -> entry.status == status end)
  end
end
