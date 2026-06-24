defmodule Acs.MCP.Tools.AnanthaQuery do
  @moduledoc """
  ACS tool handler for Anantha memory query gateway — OPTIONAL EXTENSION.

  Requires Anantha root app to be running and reachable.
  Disabled by default. Enable via config:

      config :steward_acs, :anantha_tools_enabled, true

  All 11 tools forward to Anantha's /api/query/* endpoints via Req.
  Bearer token forwarded from agent as parameter.

  Session: ETS cache keyed by agent_id (TTL 5min),
  stores %{org_id, permissions, key_id, inserted_at}

  RBAC: Each tool checks required permission against session.permissions.

  Timeouts:
    - search: 15s
    - get (synthesis, claim, observation, entity, excerpt): 10s
    - execute, export, drilldown: 30s
  """

  require Logger

  @session_table :anantha_sessions
  @session_ttl_ms 300_000  # 5 minutes

  @timeouts %{
    search: 15_000,
    get: 10_000,
    execute: 30_000
  }

  defguard is_non_empty_string(val) when is_binary(val) and byte_size(val) > 0

  def search_memory(args) do
    with {:ok, session} <- get_session(args["agent_id"]),
         :ok <- check_permission(session, "memory.search"),
         {:ok, bearer_token} <- get_bearer_token(args) do
      forward_request(:post, "/api/query/search", bearer_token, %{
        query: args["query"],
        limit: args["limit"] || 20,
        cursor: args["cursor"]
      }, @timeouts.search)
    end
  end

  def get_synthesis(args) do
    with {:ok, session} <- get_session(args["agent_id"]),
         :ok <- check_permission(session, "memory.read"),
         {:ok, bearer_token} <- get_bearer_token(args),
         {:ok, ids} <- validate_ids(args["ids"], "anantha_get_synthesis") do
      results = fetch_syntheses(bearer_token, ids)
      {:ok, %{"results" => index_results(results), "ids" => ids}}
    end
  end

  def get_claim(args) do
    with {:ok, session} <- get_session(args["agent_id"]),
         :ok <- check_permission(session, "memory.read"),
         {:ok, bearer_token} <- get_bearer_token(args),
         {:ok, ids} <- validate_ids(args["ids"], "anantha_get_claim") do
      results = fetch_claims(bearer_token, ids)
      {:ok, %{"results" => index_results(results), "ids" => ids}}
    end
  end

  def get_observation(args) do
    with {:ok, session} <- get_session(args["agent_id"]),
         :ok <- check_permission(session, "memory.read"),
         {:ok, bearer_token} <- get_bearer_token(args),
         {:ok, ids} <- validate_ids(args["ids"], "anantha_get_observation") do
      results = fetch_observations(bearer_token, ids)
      {:ok, %{"results" => index_results(results), "ids" => ids}}
    end
  end

  def get_source_excerpt(args) do
    with {:ok, session} <- get_session(args["agent_id"]),
         :ok <- check_permission(session, "memory.read"),
         {:ok, bearer_token} <- get_bearer_token(args),
         {:ok, ids} <- validate_ids(args["ids"], "anantha_get_source_excerpt") do
      results = fetch_excerpts(bearer_token, ids)
      {:ok, %{"results" => index_results(results), "ids" => ids}}
    end
  end

  def get_entity(args) do
    with {:ok, session} <- get_session(args["agent_id"]),
         :ok <- check_permission(session, "memory.read"),
         {:ok, bearer_token} <- get_bearer_token(args),
         {:ok, ids} <- validate_ids(args["ids"], "anantha_get_entity") do
      results = fetch_entities(bearer_token, ids)
      {:ok, %{"results" => index_results(results), "ids" => ids}}
    end
  end

  def execute_query(args) do
    with {:ok, session} <- get_session(args["agent_id"]),
         :ok <- check_permission(session, "analytics.query"),
         {:ok, bearer_token} <- get_bearer_token(args),
         :ok <- validate_query_spec(args, "anantha_execute_query") do
      body =
        %{
          dataset: args["dataset"],
          select: args["select"] || [],
          filters: args["filters"] || %{},
          group_by: args["group_by"],
          aggregates: args["aggregates"] || %{},
          sort: args["sort"] || [],
          limit: args["limit"] || 100,
          cursor: args["cursor"]
        }
        |> add_if_present(args, "compact")
        |> add_if_present(args, "mode")

      forward_request(:post, "/api/query/execute", bearer_token, body, @timeouts.execute)
    end
  end

  def list_datasets(args) do
    with {:ok, session} <- get_session(args["agent_id"]),
         :ok <- check_permission(session, "analytics.query"),
         {:ok, bearer_token} <- get_bearer_token(args) do
      forward_request(:post, "/api/query/describe", bearer_token, %{}, @timeouts.get)
    end
  end

  def describe_dataset(args) do
    with {:ok, session} <- get_session(args["agent_id"]),
         :ok <- check_permission(session, "analytics.query"),
         {:ok, bearer_token} <- get_bearer_token(args),
         :ok <- validate_required(args, "dataset", "anantha_describe_dataset") do
      body = %{dataset: args["dataset"]}
      forward_request(:post, "/api/query/describe", bearer_token, body, @timeouts.get)
    end
  end

  def export_dataset(args) do
    with {:ok, session} <- get_session(args["agent_id"]),
         :ok <- check_permission(session, "analytics.export"),
         {:ok, bearer_token} <- get_bearer_token(args),
         :ok <- validate_query_spec(args, "anantha_export_dataset") do
      body = %{
        dataset: args["dataset"],
        select: args["select"] || [],
        filters: args["filters"] || %{},
        group_by: args["group_by"],
        aggregates: args["aggregates"] || %{},
        sort: args["sort"] || [],
        limit: args["limit"] || 1000,
        cursor: args["cursor"],
        format: args["format"] || "json",
        max_inline_rows: args["max_inline_rows"] || 1000
      }
      forward_request(:post, "/api/query/export", bearer_token, body, @timeouts.execute)
    end
  end

  def drilldown(args) do
    with {:ok, session} <- get_session(args["agent_id"]),
         :ok <- check_permission(session, "analytics.query"),
         {:ok, bearer_token} <- get_bearer_token(args),
         :ok <- validate_required(args, "query_id", "anantha_drilldown"),
         :ok <- validate_required(args, "row_index", "anantha_drilldown") do
      body = %{
        query_id: args["query_id"],
        row_index: args["row_index"]
      }
      forward_request(:post, "/api/query/drilldown", bearer_token, body, @timeouts.execute)
    end
  end

  defp get_session(nil), do: {:error, "Missing agent_id"}
  defp get_session(agent_id) when is_binary(agent_id) do
    ensure_session_table()

    case :ets.lookup(@session_table, agent_id) do
      [{^agent_id, session}] ->
        if expired?(session) do
          :ets.delete(@session_table, agent_id)
          {:error, "Session expired. Re-authenticate."}
        else
          {:ok, session}
        end

      [] ->
        {:error, "No session found for agent. Create session first."}
    end
  end

  defp ensure_session_table do
    case :ets.info(@session_table, :name) do
      :undefined ->
        :ets.new(@session_table, [
          :set,
          :named_table,
          :public,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ ->
        :ok
    end
  end

  defp expired?(session) do
    inserted_at = Map.get(session, :inserted_at)

    cond do
      is_nil(inserted_at) -> false
      true ->
        elapsed = System.system_time(:millisecond) - inserted_at
        elapsed > @session_ttl_ms
    end
  end

  defp check_permission(session, required_permission) do
    permissions = Map.get(session, :permissions, [])

    if required_permission in permissions do
      :ok
    else
      {:error, "Forbidden: missing '#{required_permission}' permission"}
    end
  end

  defp get_bearer_token(args) do
    case args["bearer_token"] do
      token when is_binary(token) and token != "" ->
        {:ok, token}

      nil ->
        # Fall back to configured API key from Application env
        case get_api_key() do
          api_key when is_binary(api_key) and api_key != "" ->
            {:ok, api_key}

          nil ->
            {:error, "Missing required parameter: bearer_token (or set ANANTHA_API_KEY in environment)"}
        end

      _ ->
        {:error, "bearer_token must be a non-empty string"}
    end
  end

  defp validate_required(args, key, tool_name) do
    case Map.get(args, key) do
      val when is_binary(val) and val != "" -> :ok
      nil -> {:error, "Missing required parameter: #{key} for #{tool_name}"}
      _ -> {:error, "#{key} must be a non-empty string for #{tool_name}"}
    end
  end

  defp validate_query_spec(args, tool_name) do
    with :ok <- validate_required(args, "dataset", tool_name) do
      case args["dataset"] do
        d when is_binary(d) and d != "" -> :ok
        _ -> {:error, "dataset must be a non-empty string for #{tool_name}"}
      end
    end
  end

  # Add a key to a map only if the value is present (not nil)
  defp add_if_present(map, args, key) do
    case Map.get(args, key) do
      nil -> map
      value -> Map.put(map, key, value)
    end
  end

  defp validate_ids(ids, _tool_name) when is_list(ids) and length(ids) > 0 do
    if Enum.all?(ids, &is_binary/1), do: {:ok, ids}, else: {:error, "ids must be strings"}
  end
  defp validate_ids(nil, tool_name), do: {:error, "Missing required param: ids for #{tool_name}"}
  defp validate_ids([], tool_name), do: {:error, "ids cannot be empty for #{tool_name}"}
  defp validate_ids(_ids, _tool_name), do: {:error, "ids must be a non-empty list"}

  # Index results by position so agent can map back by index
  defp index_results(results) when is_list(results) do
    results
    |> Enum.with_index()
    |> Map.new(fn {item, idx} -> {Integer.to_string(idx), item} end)
  end

  defp fetch_syntheses(bearer_token, ids) do
    case forward_request(:post, "/api/query/syntheses/batch", bearer_token, %{"ids" => ids}, @timeouts.get) do
      {:ok, %{"syntheses" => syntheses}} -> syntheses
      {:ok, %{"results" => results}} -> results  # fallback direct results
      error -> error
    end
  end

  defp fetch_claims(bearer_token, ids) do
    case forward_request(:post, "/api/query/claims/batch", bearer_token, %{"ids" => ids}, @timeouts.get) do
      {:ok, %{"claims" => claims}} -> claims
      {:ok, %{"results" => results}} -> results
      error -> error
    end
  end

  defp fetch_observations(bearer_token, ids) do
    case forward_request(:post, "/api/query/observations/batch", bearer_token, %{"ids" => ids}, @timeouts.get) do
      {:ok, %{"observations" => observations}} -> observations
      {:ok, %{"results" => results}} -> results
      error -> error
    end
  end

  defp fetch_excerpts(bearer_token, ids) do
    case forward_request(:post, "/api/query/excerpts/batch", bearer_token, %{"ids" => ids}, @timeouts.get) do
      {:ok, %{"excerpts" => excerpts}} -> excerpts
      {:ok, %{"results" => results}} -> results
      error -> error
    end
  end

  defp fetch_entities(bearer_token, ids) do
    case forward_request(:post, "/api/query/entities/batch", bearer_token, %{"ids" => ids}, @timeouts.get) do
      {:ok, %{"entities" => entities}} -> entities
      {:ok, %{"results" => results}} -> results
      error -> error
    end
  end

  defp base_url do
    Application.get_env(:steward_acs, :anantha, [])
    |> Keyword.get(:base_url, "http://localhost:4000")
  end

  @doc """
  Returns the configured Anantha API key from config map or Application env.

  ## Config Setup

  Set via Application env in `config/runtime.exs`:
      config :steward_acs, :anantha,
        api_key: "sk_live_...",
        base_url: "http://localhost:4000"

  Or via opencode.json `anantha` section when using the Safety Connect analyst workspace.
  """
  def get_api_key(config \\ []) do
    config
    |> Keyword.get(:api_key)
    || Application.get_env(:steward_acs, :anantha, [])[:api_key]
  end

  defp forward_request(method, path, bearer_token, body, timeout) do
    url = base_url() <> path

    headers = [
      {"authorization", "Bearer #{bearer_token}"},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    opts = [timeout: timeout, receive_timeout: timeout]

    result =
      case method do
        :get ->
          Req.request(method: :get, url: url, headers: headers, options: opts)

        :post ->
          Req.request(method: :post, url: url, headers: headers, json: body || %{}, options: opts)
      end

    handle_response(result)
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    handle_http_status(status, body)
  end

  defp handle_response({:error, %Req.TransportError{reason: :timeout}}) do
    {:error, "Request timed out"}
  end

  defp handle_response({:error, %Req.TransportError{reason: :econnrefused}}) do
    {:error, "Anantha unavailable: connection refused"}
  end

  defp handle_response({:error, reason}) do
    Logger.error("[AnanthaQuery] Request failed: #{inspect(reason)}")
    {:error, "Anantha request failed: #{inspect(reason)}"}
  end

  defp handle_http_status(status, body) when status in [200, 201] do
    {:ok, body}
  end

  defp handle_http_status(401, _body) do
    {:error, "Unauthorized: invalid or expired bearer token"}
  end

  defp handle_http_status(403, _body) do
    {:error, "Forbidden: insufficient permissions"}
  end

  defp handle_http_status(404, _body) do
    {:error, "Not found"}
  end

  defp handle_http_status(429, body) do
    retry_after = Map.get(body, "retry_after", 60)
    {:error, "Rate limited. Retry after #{retry_after} seconds."}
  end

  defp handle_http_status(400, body) do
    errors = Map.get(body, "errors", [])
    message = if is_list(errors) and length(errors) > 0 do
      Enum.join(errors, "; ")
    else
      Map.get(body, "message", "Invalid request")
    end
    {:error, "Invalid input: #{message}"}
  end

  defp handle_http_status(status, body) when status >= 500 do
    Logger.error("[AnanthaQuery] Server error #{status}: #{inspect(body)}")
    {:error, "Anantha server error"}
  end

  defp handle_http_status(status, body) do
    Logger.warning("[AnanthaQuery] Unexpected status #{status}: #{inspect(body)}")
    {:error, "Request failed with status #{status}"}
  end
  @doc """
  Store a session for an agent. Called by ACS when an agent authenticates with an API key.
  """
  def store_session(agent_id, %{org_id: org_id, permissions: permissions, key_id: key_id}) do
    ensure_session_table()

    session = %{
      org_id: org_id,
      permissions: permissions,
      key_id: key_id,
      inserted_at: System.system_time(:millisecond)
    }

    :ets.insert(@session_table, {agent_id, session})
    :ok
  end

  @doc """
  Remove a session for an agent. Called when agent logs out or session expires.
  """
  def clear_session(agent_id) do
    ensure_session_table()
    :ets.delete(@session_table, agent_id)
    :ok
  end

  @doc """
  List all active sessions (for debugging).
  """
  def list_sessions do
    ensure_session_table()

    :ets.tab2list(@session_table)
    |> Enum.map(fn {agent_id, session} ->
      Map.put(session, :agent_id, agent_id)
    end)
  end
end