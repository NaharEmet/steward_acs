defmodule Acs.LLM do
  @moduledoc """
  LLM wrapper for Memory Auditor evaluations.

  Uses direct Req.post/1 calls with OpenAI-compatible API format.
  Iterates through all enabled LLM providers in priority order until one succeeds.
  Evaluates proposed memories for quality, noise, contradictions, and title quality.
  """

  require Logger

  alias AnanthaJson.ResponseParser

  # Provider definitions — all available providers for memory evaluation.
  # Add new providers by adding an entry here.
  @providers %{
    "nim" => %{
      api_key_env: "NIM_API_KEY",
      config_key: :nvidia_nim_api_key,
      base_url: "https://integrate.api.nvidia.com/v1",
      model: "meta/llama-3.3-70b-instruct",
      supports_json_mode: false,
      max_tokens: nil,
      rate_limit: 40,
      rate_window_ms: 60_000
    },
    "mimo" => %{
      api_key_env: "MIMO_API_KEY",
      config_key: :mimo_api_key,
      base_url: "https://token-plan-sgp.xiaomimimo.com/v1",
      model: "mimo-v2.5",
      supports_json_mode: true,
      suppress_thinking: true,
      max_tokens: 4096,
      rate_limit: 40,
      rate_window_ms: 60_000
    },
    "minimax" => %{
      api_key_env: "MINIMAX_API_KEY",
      config_key: :minimax_api_key,
      base_url: "https://api.minimax.io/v1",
      model: "minimax-m2.7",
      supports_json_mode: true,
      max_tokens: nil,
      rate_limit: 40,
      rate_window_ms: 60_000
    }
  }

  # Number of approved memories to include for contradiction detection
  @max_context_memories 5

  @doc """
  Evaluates a proposed memory entry for quality, noise, and contradictions.

  Uses JSON wrappers around memory content to protect against prompt injection.

  ## Parameters
    - memory_id: The ID of the memory being evaluated (for logging)
    - memory: Map with :title, :content, :kind, :scope_path, :tags keys

  ## Returns
    - `{:ok, evaluation}` on success with evaluation map
    - `{:error, reason}` on failure

  ## Evaluation Schema
    - `:quality_score` - Integer 1-5 rating of overall content quality
    - `:title_quality` - Integer 1-5 rating of title descriptiveness
    - `:is_noise` - Boolean indicating if memory is pure noise
    - `:recommendation` - String: "approve", "reject", or "human_review"
    - `:reasoning` - String explaining the evaluation
    - `:improvements` - Optional string with suggested improvements
    - `:suggested_title` - Optional improved title
    - `:is_duplicate_of` - Optional ID of duplicate memory if detected
  """
  @spec evaluate_memory(String.t(), map()) :: {:ok, map()} | {:error, atom() | String.t()}
  def evaluate_memory(memory_id, memory) when is_map(memory) do
    # Guard: validate required fields at boundary
    with {:ok, _} <- validate_required_fields(memory) do
      do_evaluate(memory_id, memory)
    end
  end

  def evaluate_memory(memory_id, invalid) do
    {:error,
     {:invalid_input, "memory_id #{memory_id}: memory must be a map, got: #{inspect(invalid)}"}}
  end

  # Backward compatibility - deprecated, use evaluate_memory/2
  def evaluate_memory(memory) when is_map(memory) do
    evaluate_memory("unknown", memory)
  end

  def evaluate_memory(invalid) do
    {:error, {:invalid_input, "memory must be a map, got: #{inspect(invalid)}"}}
  end

  # Validate required fields early - fail fast with descriptive errors
  defp validate_required_fields(memory) do
    required = [:title, :content, :kind, :scope_path]

    missing =
      Enum.reduce(required, [], fn field, acc ->
        case Map.get(memory, field) do
          nil -> [field | acc]
          "" -> [field | acc]
          _ -> acc
        end
      end)

    case missing do
      [] -> {:ok, memory}
      _ -> {:error, {:missing_required_fields, Enum.reverse(missing)}}
    end
  end

  # Core evaluation logic with provider iteration and retries
  defp do_evaluate(memory_id, memory) do
    prompt = build_evaluation_prompt(memory, fetch_approved_memories_for_context(memory.scope_path))

    providers = get_enabled_providers()

    if providers == [] do
      {:error, :no_providers_enabled}
    else
      try_providers(memory_id, providers, prompt)
    end
  end

  defp try_providers(memory_id, providers, prompt) do
    try_providers(memory_id, providers, prompt, [])
  end

  defp try_providers(_memory_id, [], _prompt, errors) do
    {:error, {:all_providers_failed, errors |> Enum.reverse() |> Enum.take(3)}}
  end

  defp try_providers(memory_id, [provider_id | rest], prompt, errors) do
    config = @providers[provider_id]
    Logger.info("[Acs.LLM] Trying provider: #{provider_id} with model #{config.model}")

    case call_provider(provider_id, config, prompt) do
      {:ok, evaluation} -> {:ok, evaluation}
      {:error, reason} -> handle_failure(memory_id, provider_id, rest, prompt, errors, reason)
    end
  end

  defp handle_failure(memory_id, provider_id, rest, prompt, errors, reason) do
    Logger.warning("[Acs.LLM] Provider #{provider_id} failed: #{inspect(reason)}")
    try_providers(memory_id, rest, prompt, [{provider_id, reason} | errors])
  end

  defp call_provider(provider_id, config, prompt) do
    api_key =
      Application.get_env(:steward_acs, config.config_key) ||
        System.get_env(config.api_key_env)

    if is_nil(api_key) or api_key == "" do
      {:error, :missing_api_key}
    else
      case check_rate_limit(provider_id, config) do
        :rate_limited ->
          Logger.warning("[Acs.LLM] Rate limited on #{provider_id}, waiting...")
          Process.sleep(1000)
          {:error, :rate_limited}

        :ok ->
          do_call_provider(config, prompt, api_key)
      end
    end
  end

  defp do_call_provider(config, prompt, api_key) do
    body = build_request_body(config, prompt)

    Logger.info("[Acs.LLM] Calling #{config.base_url} with model #{config.model}")

    case Req.post(
      url: "#{config.base_url}/chat/completions",
      json: body,
      headers: [{"Authorization", "Bearer #{api_key}"}],
      receive_timeout: 30_000
    ) do
      {:ok, %{status: 200, body: response_body}} ->
        extract_json_from_message(response_body)

      {:ok, %{status: status, body: response_body}} ->
        Logger.warning("[Acs.LLM] Provider returned status #{status}")
        {:error, {:http_error, status, response_body}}

      {:error, reason} ->
        Logger.error("[Acs.LLM] Provider request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp build_request_body(config, prompt) do
    messages = [
      %{role: "user", content: prompt}
    ]

    base = %{
      model: config.model,
      messages: messages,
      temperature: 0.0,
      max_tokens: config.max_tokens
    }

    body =
      if config.supports_json_mode do
        Map.put(base, :response_format, %{type: "json_object"})
      else
        base
      end

    if config[:suppress_thinking] do
      Map.put(body, :thinking, %{type: "disabled"})
    else
      body
    end
  end

  defp extract_json_from_message(message) do
    choices = message["choices"] || message[:choices] || []

    case choices do
      [first_choice | _] ->
        message_content = first_choice["message"] || first_choice[:message] || %{}
        content = message_content["content"] || message_content[:content] || ""
        reasoning = first_choice["reasoning"] || first_choice[:reasoning] || ""

        case {content, reasoning} do
          {content, _} when is_binary(content) and content != "" ->
            case try_extract_json(content) do
              {:ok, _} = success -> success
              :error ->
                # If content extraction fails, try reasoning content
                try_reasoning_content(reasoning)
            end

          {_, reasoning} when is_binary(reasoning) and reasoning != "" ->
            try_reasoning_content(reasoning)

          _ ->
            Logger.warning("[Acs.LLM] Empty response - message keys: #{inspect(Map.keys(message))}")
            {:error, :empty_response}
        end

      _ ->
        Logger.warning("[Acs.LLM] No choices in response")
        {:error, :no_choices}
    end
  end

  defp try_reasoning_content(nil), do: {:error, :empty_response}

  defp try_reasoning_content(reasoning) do
    case try_extract_json(reasoning) do
      {:ok, _} = success -> success
      :error -> {:error, :invalid_json_response}
    end
  end

  # ── JSON extraction and decoding ──────────────────────────────────────

  defp try_extract_json(nil), do: :error

  defp try_extract_json(text) do
    text
    |> String.trim()
    |> strip_thinking_tags()
    |> ResponseParser.parse()
    |> case do
      {:ok, _} = success -> success
      _ -> :error
    end
  end

  @doc false
  # Extract valid JSON from LLM response content that may have markdown code fence wrapping
  # or thinking tags. Reasoning models (MiMo v2.5) often wrap output in <thinking>...</thinking>
  # blocks followed by the actual JSON response.
  #
  # Uses the shared AnanthaJson.ResponseParser from the :llm_utils library.
  def extract_json_content(nil), do: :error

  def extract_json_content(content) when is_binary(content) do
    content
    |> String.trim()
    |> strip_thinking_tags()
    |> ResponseParser.parse()
    |> case do
      {:ok, _} = success -> success
      _ -> :error
    end
  end

  def extract_json_content(_), do: :error

  # Strip <thinking>...</thinking> blocks from reasoning model output.
  # MiMo v2.5 and similar reasoning models wrap their reasoning in these tags.
  # This is ACS-specific — the shared ResponseParser doesn't strip thinking tags.
  defp strip_thinking_tags(content) do
    String.replace(content, ~r/<thinking>[\s\S]*?<\/thinking>/i, "")
    |> String.trim()
  end

  # Generic rate limiter using per-provider ETS tables
  defp check_rate_limit(provider_id, config) do
    table_name = :"#{provider_id}_rate_tracker"
    ensure_rate_table(table_name)

    now = System.monotonic_time(:millisecond)
    cutoff = now - config.rate_window_ms

    :ets.select_delete(table_name, [{{:_, :"$1"}, [{:<, :"$1", cutoff}], [true, []]}])

    timestamps =
      :ets.select(table_name, [{{:_, :"$1"}, [{:>, :"$1", cutoff}], [:"$1"]}])

    if length(timestamps) >= config.rate_limit do
      :rate_limited
    else
      :ets.insert(table_name, {make_ref(), now})
      :ok
    end
  end

  defp ensure_rate_table(table_name) do
    case :ets.info(table_name, :name) do
      :undefined ->
        try do
          :ets.new(table_name, [:set, :public, :named_table])
        rescue
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  # Check if a provider is enabled (whitelist-based).
  # If enabled list is empty, all providers are considered enabled.
  defp provider_enabled?(provider_id) do
    enabled = Application.get_env(:steward_acs, :enabled_llm_providers, [])
    enabled == [] or provider_id in enabled
  end

  # Check if a provider is enabled (whitelist-based)
  defp get_enabled_providers do
    @providers
    |> Map.keys()
    |> Enum.filter(&provider_enabled?/1)
    |> Enum.filter(fn id ->
      config = @providers[id]

      api_key =
        Application.get_env(:steward_acs, config.config_key) ||
          System.get_env(config.api_key_env)

      is_binary(api_key) and api_key != ""
    end)
  end

  # Fetch up to 5 approved memories from the same scope for contradiction detection
  #
  # Indexer.list_memories/1 returns a flat list (Repo.all/2 result), not an {:ok, list} tuple,
  # so we handle the list directly with a guard for unexpected types.
  defp fetch_approved_memories_for_context(scope_path) when is_binary(scope_path) do
    memories =
      Acs.Memory.Indexer.list_memories(
        scope_path: scope_path,
        status: "approved",
        limit: @max_context_memories
      )

    if is_list(memories) do
      Enum.take(memories, @max_context_memories)
    else
      []
    end
  end

  defp fetch_approved_memories_for_context(_), do: []

  # Build evaluation prompt with JSON wrappers for injection protection
  defp build_evaluation_prompt(memory, context_memories) do
    memory_json =
      Jason.encode!(%{
        title: memory.title || "",
        content: memory.content || "",
        kind: memory.kind || "",
        scope_path: memory.scope_path || "",
        tags: memory.tags || []
      })

    existing_memories_json = Jason.encode!(context_memories)

    """
    You are a memory quality auditor. Evaluate memory entries for content quality, title descriptiveness, noise, and contradictions with existing knowledge.

    {"memory_entry": #{memory_json}}

    {"existing_memories": #{existing_memories_json}}

    Respond ONLY with valid JSON. Use single-line values only — no multi-line strings. Fields: quality_score(1-5), title_quality(1-5), is_noise(bool), recommendation(one of: "approve","reject","human_review"), reasoning, improvements, suggested_title, is_duplicate_of

    For recommendation, you MUST use exactly one of: "approve", "reject", or "human_review".
    """
  end

end
