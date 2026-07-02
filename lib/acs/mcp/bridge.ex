defmodule Acs.MCP.Bridge do
  @moduledoc """
  HTTP Bridge for routing MCP tool calls to external application REST APIs.

  Reads tool definitions (base_url, endpoint, method) and makes HTTP requests
  via the Req library, transforming responses back to MCP tool results.
  """

  require Logger

  @default_timeout 30_000

  @session_table :mcp_sessions
  @session_ttl_ms 300_000  # 5 minutes

  defp ensure_session_table do
    case :ets.info(@session_table, :name) do
      :undefined ->
        :ets.new(@session_table, [:set, :named_table, :protected, read_concurrency: true, write_concurrency: true])
      _ -> :ok
    end
  end

  @doc """
  Calls an external tool via HTTP.

  ## Parameters
    - tool_def: Map with keys `base_url`, `endpoint`, `method`, `params`
    - args: Map of MCP tool arguments (from the agent)

  ## Returns
    - `{:ok, result_map}` on success
    - `{:error, reason}` on failure
  """
  def call_tool(tool_def, args) do
    base_url = tool_def["base_url"]
    endpoint = tool_def["endpoint"]
    method = tool_def["method"] || "POST"
    tool_name = tool_def["name"]

    # Session-aware dispatch: resolve session_id to api_key
    case resolve_session(args) do
      {:error, reason} ->
        {:error, reason}

      args ->
        url = build_url(base_url, endpoint)

        case Acs.MCP.UrlSafety.validate_outbound_url(url) do
          :ok ->
            do_http_call(tool_def, args, url, method, tool_name)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp do_http_call(tool_def, args, url, method, tool_name) do
    api_key = args["api_key"]
    app_config = resolve_app_config(tool_def["base_url"])
    timeout = tool_def["timeout"] || app_config[:timeout_ms] || @default_timeout

    Logger.info("Bridge: calling #{method} #{url} for tool '#{tool_name}'")

    headers = build_headers(args, app_config)
    req_opts = [
      url: url,
      method: String.downcase(method),
      headers: headers,
      timeout: timeout
    ]

    req_opts =
      case String.upcase(method) do
        m when m in ["POST", "PUT", "PATCH"] ->
          _body = build_body(tool_def, args)
          Keyword.put(req_opts, :json, _body)

        _ ->
          _query = build_query(tool_def, args)
          Keyword.put(req_opts, :params, _query)
      end

    case request_with_opts(req_opts) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        result = format_response(body, tool_name)
        result = maybe_transform_response(result, tool_def)
        result = maybe_store_session(tool_name, result, api_key)
        {:ok, result}

      {:ok, %{status: status, body: body}} ->
        error_msg = format_error_body(body)
        Logger.warning("Bridge: tool '#{tool_name}' returned HTTP #{status}: #{error_msg}")
        {:error, "HTTP #{status}: #{error_msg}"}

      {:error, reason} ->
        Logger.error("Bridge: tool '#{tool_name}' HTTP error: #{inspect(reason)}")
        {:error, "HTTP request failed: #{inspect(reason)}"}
    end
  end

  @doc """
  Quick health check of an app by hitting its base URL.
  Returns `{:ok, map}` or `{:error, reason}`.
  """
  def health_check(base_url) do
    case Acs.MCP.UrlSafety.validate_outbound_url(base_url) do
      :ok ->
        case request_with_opts(url: base_url, method: "get", timeout: 5_000) do
          {:ok, %{status: s, body: b}} when s in 200..399 ->
            {:ok, %{status: s, body: b, reachable: true}}

          {:ok, %{status: s}} ->
            {:ok, %{status: s, reachable: true}}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Session management ---

  defp resolve_session(args) do
    case args["_session_id"] do
      nil ->
        args

      session_id when is_binary(session_id) ->
        ensure_session_table()

        case :ets.lookup(@session_table, session_id) do
          [{^session_id, session}] ->
            if expired?(session) do
              :ets.delete(@session_table, session_id)
              {:error, "Session expired. Re-authenticate with ant_authenticate."}
            else
              Map.put(args, "api_key", session.api_key)
            end

          [] ->
            {:error, "Session not found. Authenticate first with ant_authenticate."}
        end
    end
  end

  defp expired?(session) do
    System.monotonic_time(:millisecond) - session.inserted_at > @session_ttl_ms
  end

  defp maybe_store_session("ant_authenticate", result, api_key) when is_map(result) and is_binary(api_key) do
    if result["status"] == "ok" and result["org_id"] and result["key_prefix"] do
      ensure_session_table()
      session_id = "sess_#{random_string(16)}"

      session = %{
        org_id: result["org_id"],
        org_name: result["org_name"],
        role: result["role"],
        permissions: result["permissions"],
        key_id: result["key_prefix"],
        api_key: api_key,
        inserted_at: System.monotonic_time(:millisecond)
      }

      true = :ets.insert(@session_table, {session_id, session})

      result
      |> Map.put("session_id", session_id)
    else
      result
    end
  end

  defp maybe_store_session(_tool_name, result, _api_key), do: result

  defp random_string(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, length)
  end

  # --- Private ---

  defp build_url(base_url, endpoint) do
    base = String.trim_trailing(base_url, "/")
    ep = String.trim_leading(endpoint, "/")
    "#{base}/#{ep}"
  end

  defp build_body(tool_def, args) do
    # Map MCP args to the params defined in the tool definition
    param_names = Enum.map(tool_def["params"] || [], & &1["name"])

    # Only include params that are defined in the tool's schema
    Map.take(args, param_names)
  end

  defp build_query(tool_def, args) do
    build_body(tool_def, args)
  end

  defp build_headers(args, app_config \\ []) do
    headers = [{"content-type", "application/json"}]

    header_name = app_config[:auth_header_name] || "authorization"
    header_scheme = app_config[:auth_header_scheme] || "Bearer"

    auth_value =
      case args["api_key"] do
        key when is_binary(key) and key != "" ->
          auth_header_value(key, header_scheme)

        _ ->
          service_api_key = Application.get_env(:steward_acs, :service_api_key)

          case service_api_key do
            key when is_binary(key) and key != "" ->
              auth_header_value(key, header_scheme)

            _ ->
              nil
          end
      end

    if auth_value do
      [{header_name, auth_value} | headers]
    else
      headers
    end
  end

  defp auth_header_value(key, ""), do: key
  defp auth_header_value(key, scheme), do: "#{scheme} #{key}"

  defp resolve_app_config(base_url) when is_binary(base_url) do
    matched =
      Acs.Apps.Config.list_apps()
      |> Enum.find(fn {_name, config} ->
        configured_url = Keyword.get(config, :base_url)
        configured_url && base_url == configured_url
      end)

    case matched do
      {_name, config} -> config
      nil -> []
    end
  end

  defp resolve_app_config(nil), do: []

  defp request_with_opts(opts) do
    req = Req.new(Keyword.drop(opts, [:url, :method, :json, :params, :timeout]))

    url = opts[:url]
    method = opts[:method] || "get"
    timeout = opts[:timeout] || @default_timeout

    case method do
      "get" ->
        Req.get(req, url: url, params: opts[:params], receive_timeout: timeout)

      "post" ->
        Req.post(req, url: url, json: opts[:json], receive_timeout: timeout)

      "put" ->
        Req.put(req, url: url, json: opts[:json], receive_timeout: timeout)

      "patch" ->
        Req.patch(req, url: url, json: opts[:json], receive_timeout: timeout)

      "delete" ->
        Req.delete(req, url: url, params: opts[:params], receive_timeout: timeout)
    end
  end

  defp format_response(nil, _tool_name), do: %{status: "ok"}
  defp format_response(body, _tool_name) when is_map(body), do: body
  defp format_response(body, _tool_name) when is_list(body), do: %{items: body, count: length(body)}

  defp format_response(body, _tool_name) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> format_response(decoded, "")
      _ -> %{result: body}
    end
  end

  defp format_response(body, _tool_name), do: %{result: body}

  defp format_error_body(nil), do: "Unknown error"
  defp format_error_body(%{"error" => msg}) when is_binary(msg), do: msg
  defp format_error_body(%{"message" => msg}) when is_binary(msg), do: msg

  defp format_error_body(body) when is_map(body) do
    case Jason.encode(body) do
      {:ok, json} -> json
      _ -> inspect(body)
    end
  end

  defp format_error_body(body) when is_binary(body), do: body
  defp format_error_body(body), do: inspect(body)

  # --- Response Transform ---

  defp maybe_transform_response(result, tool_def) do
    transform = tool_def["response_transform"]

    cond do
      is_nil(transform) ->
        result

      extract_key = transform["extract_key"] ->
        result = extract_key_response(result, extract_key)

        if transform["index"] do
          index_results(result)
        else
          result
        end

      true ->
        result
    end
  end

  defp extract_key_response(result, key) do
    case result do
      %{^key => value} when is_list(value) -> value
      %{} -> result
      _ -> result
    end
  end

  defp index_results([]), do: %{"results" => %{}, "ids" => []}

  defp index_results(results) when is_list(results) do
    indexed =
      results
      |> Enum.with_index()
      |> Map.new(fn {item, idx} -> {Integer.to_string(idx), item} end)

    ids = Enum.map(0..(length(results) - 1), fn i -> Integer.to_string(i) end)
    %{"results" => indexed, "ids" => ids}
  end

  defp index_results(%{"results" => _} = already_indexed), do: already_indexed
  defp index_results(other), do: other
end
