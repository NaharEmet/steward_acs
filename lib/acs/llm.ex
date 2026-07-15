defmodule Acs.LLM do
  @moduledoc """
  LLM wrapper for Memory Auditor evaluations.

  Uses shared `LLMUtils.Client` for HTTP calls, provider configs, rate limiting,
  circuit breaking, and response normalization.
  Keeps evaluation-specific logic: prompt building, provider iteration, contradiction detection.
  """

  require Logger

  alias LLMUtils.ResponseParser

  # Provider priority order for evaluations
  @provider_priority ["nim", "mimo", "minimax", "openai"]

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
    with {:ok, _} <- validate_required_fields(memory) do
      do_evaluate_memory(memory_id, memory)
    end
  end

  def evaluate_memory(memory_id, invalid) do
    {:error,
     {:invalid_input, "memory_id #{memory_id}: memory must be a map, got: #{inspect(invalid)}"}}
  end

  # Backward compatibility — deprecated, use evaluate_memory/2
  def evaluate_memory(memory) when is_map(memory) do
    evaluate_memory("unknown", memory)
  end

  def evaluate_memory(invalid) do
    {:error, {:invalid_input, "memory must be a map, got: #{inspect(invalid)}"}}
  end

  @doc """
  Evaluates a skill for actionability, completeness, and description quality.
  """
  @spec evaluate_skill(String.t(), map()) :: {:ok, map()} | {:error, atom() | String.t()}
  def evaluate_skill(skill_name, skill) when is_map(skill) do
    with :ok <- validate_skill_fields(skill) do
      do_evaluate_skill(skill_name, skill)
    end
  end

  def evaluate_skill(skill_name, invalid) do
    {:error,
     {:invalid_input, "skill_name #{skill_name}: skill must be a map, got: #{inspect(invalid)}"}}
  end

  # ── Validation ────────────────────────────────────────────────────────

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

  # ── Core evaluation logic ───────────────────────────────────────────

  defp validate_skill_fields(skill) do
    missing =
      Enum.reduce([:name, :content], [], fn field, acc ->
        case Map.get(skill, field) do
          nil -> [field | acc]
          "" -> [field | acc]
          _ -> acc
        end
      end)

    case missing do
      [] -> :ok
      _ -> {:error, {:missing_required_fields, Enum.reverse(missing)}}
    end
  end

  defp do_evaluate_memory(memory_id, memory) do
    prompt =
      build_evaluation_prompt(memory, fetch_approved_memories_for_context(memory.scope_path))

    providers = get_enabled_providers()

    if providers == [] do
      {:error, :no_providers_enabled}
    else
      try_providers(memory_id, providers, prompt)
    end
  end

  defp do_evaluate_skill(skill_name, skill) do
    context = Acs.Skills.Store.context_for_audit(skill.name)
    prompt = build_skill_evaluation_prompt(skill, context)
    providers = get_enabled_providers()

    if providers == [] do
      {:error, :no_providers_enabled}
    else
      try_providers(skill_name, providers, prompt)
    end
  end

  # ── Provider iteration ──────────────────────────────────────────────
  # Tries providers in priority order until one succeeds.
  # Uses LLMUtils.Client for the actual HTTP call.

  defp try_providers(memory_id, providers, prompt) do
    try_providers(memory_id, providers, prompt, [])
  end

  defp try_providers(_memory_id, [], _prompt, errors) do
    {:error, {:all_providers_failed, errors |> Enum.reverse() |> Enum.take(3)}}
  end

  defp try_providers(memory_id, [provider_id | rest], prompt, errors) do
    Logger.info("[Acs.LLM] Trying provider: #{provider_id}")

    case call_provider(provider_id, prompt) do
      {:ok, evaluation} ->
        {:ok, evaluation}

      {:error, reason} ->
        Logger.warning("[Acs.LLM] Provider #{provider_id} failed: #{inspect(reason)}")
        try_providers(memory_id, rest, prompt, [{provider_id, reason} | errors])
    end
  end

  # ── Provider call ────────────────────────────────────────────────────
  # Uses LLMUtils.Client with options for metrics, rate limiting, logging.

  defp call_provider(provider_id, prompt) do
    config = LLMUtils.Providers.get(provider_id)

    if is_nil(config) do
      {:error, :unknown_provider}
    else
      api_key = resolve_api_key(provider_id)

      messages = [%{role: "user", content: prompt}]

      model =
        provider_overrides(provider_id, :model) ||
          config.default_model

      base_url =
        provider_overrides(provider_id, :base_url)

      opts = [
        model: model,
        api_key: api_key,
        json_mode: config.supports_json_mode,
        suppress_thinking: Map.get(config, :suppress_thinking, false),
        max_tokens: 4096,
        temperature: 0.0,
        enable_rate_limiter: true,
        enable_circuit_breaker: false,
        enable_metrics: true,
        enable_logging: true
      ]

      opts = if base_url, do: Keyword.put(opts, :base_url, base_url), else: opts

      case LLMUtils.Client.chat_completion(messages, provider_id, opts) do
        {:ok, %{content: content}} ->
          extract_evaluation(content)

        {:ok, response} ->
          Logger.warning(
            "[Acs.LLM] Unexpected response format from #{provider_id}: #{inspect(response)}"
          )

          {:error, :unexpected_response_format}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Allow OpenAI-compatible providers to override base_url and model via env vars.
  # OPENAI_BASE_URL — override the API endpoint (e.g., http://localhost:8000/v1)
  # OPENAI_MODEL   — override the model name (e.g., gpt-4o-mini, local-model)
  defp provider_overrides("openai", :base_url),
    do: System.get_env("OPENAI_BASE_URL") || Application.get_env(:steward_acs, :openai_base_url)

  defp provider_overrides("openai", :model),
    do: System.get_env("OPENAI_MODEL") || Application.get_env(:steward_acs, :openai_model)

  defp provider_overrides(_, _), do: nil

  # ── API key resolution ───────────────────────────────────────────────
  # Checks Application config first (set in runtime.exs), then system env.

  defp resolve_api_key(provider_id) do
    Application.get_env(:steward_acs, :"#{provider_id}_api_key") ||
      System.get_env(LLMUtils.Provider.env_key(provider_id))
  end

  # ── Evaluation extraction ────────────────────────────────────────────

  defp extract_evaluation(content) when is_map(content) do
    {:ok, content}
  end

  defp extract_evaluation(content) when is_binary(content) do
    content
    |> String.trim()
    |> strip_thinking_tags()
    |> ResponseParser.parse()
    |> case do
      {:ok, _} = success -> success
      {:error, _} -> {:error, :invalid_json_response}
    end
  end

  defp extract_evaluation(_), do: {:error, :invalid_json_response}

  # ── Public JSON extraction (backward compat, used in tests) ──────────

  @doc false
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

  # ── Thinking tag stripping ──────────────────────────────────────────
  # Reasoning model responses may include <thinking>...</thinking> blocks.
  # The shared LLMUtils.Client strips these from HTTP responses, but
  # we also strip from raw content as a safety net.

  defp strip_thinking_tags(content) do
    String.replace(content, ~r/<thinking>[\s\S]*?<\/thinking>/i, "")
    |> String.trim()
  end

  # ── Provider filtering ──────────────────────────────────────────────
  # Checks which providers are enabled (whitelist) and have valid API keys.

  defp get_enabled_providers do
    @provider_priority
    |> Enum.filter(&provider_enabled?/1)
    |> Enum.filter(&has_valid_api_key?/1)
  end

  defp provider_enabled?(provider_id) do
    enabled = Application.get_env(:steward_acs, :enabled_llm_providers, [])
    enabled == [] or provider_id in enabled
  end

  defp has_valid_api_key?(provider_id) do
    api_key = resolve_api_key(provider_id)
    is_binary(api_key) and api_key != ""
  end

  # ── Context fetch ────────────────────────────────────────────────────

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

  # ── Evaluation prompt ────────────────────────────────────────────────
  # Default prompt used when MEMORY_EVALUATION_PROMPT_PATH is not set or unreadable.
  # Supports {{memory_json}} and {{existing_memories_json}} template variables.

  @default_evaluation_prompt """
  You are a memory quality auditor. Evaluate memory entries for content quality, title descriptiveness, noise, and contradictions with existing knowledge.

  {"memory_entry": {{memory_json}}}

  {"existing_memories": {{existing_memories_json}}}

  Respond ONLY with valid JSON. Use single-line values only — no multi-line strings. Fields: quality_score(1-5), title_quality(1-5), is_noise(bool), recommendation(one of: "approve","reject","human_review"), reasoning, improvements, suggested_title, is_duplicate_of

  For recommendation, you MUST use exactly one of: "approve", "reject", or "human_review".
  """

  @default_skill_evaluation_prompt """
  You are a skill quality auditor. Evaluate skills for actionability and completeness.

  {"skill": {{skill_json}}}

  {"existing_skills": {{existing_skills_json}}}

  Respond ONLY with valid JSON. Fields: quality_score(1-5), description_quality(1-5), is_actionable(bool), recommendation("ok"|"needs_improvement"|"failing"), reasoning, improvements, suggested_description
  """

  defp build_skill_evaluation_prompt(skill, context_skills) do
    skill_json =
      Jason.encode!(%{
        name: skill.name || "",
        description: skill.description || "",
        content: skill.content || "",
        tags: skill.tags || []
      })

    existing_skills_json = Jason.encode!(context_skills)

    template =
      Acs.Prompts.load("skills", "evaluate", default: @default_skill_evaluation_prompt)

    template
    |> String.replace("{{skill_json}}", skill_json)
    |> String.replace("{{existing_skills_json}}", existing_skills_json)
  end

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

    prompt_template = load_prompt_template()
    do_interpolate(prompt_template, memory_json, existing_memories_json)
  end

  defp load_prompt_template do
    case memory_prompt_override() do
      {:ok, content} -> content
      :default -> Acs.Prompts.load("memory", "evaluate", default: @default_evaluation_prompt)
    end
  end

  defp memory_prompt_override do
    with path when is_binary(path) <- System.get_env("MEMORY_EVALUATION_PROMPT_PATH"),
         trimmed when trimmed != "" <- String.trim(path),
         true <- Path.type(trimmed) == :absolute,
         true <- File.exists?(trimmed),
         {:ok, content} <- File.read(trimmed) do
      {:ok, content}
    else
      {:error, reason} ->
        Logger.warning(
          "[Acs.LLM] Failed to read MEMORY_EVALUATION_PROMPT_PATH: #{inspect(reason)}. Using default."
        )

        :default

      _ ->
        :default
    end
  end

  defp do_interpolate(template, memory_json, existing_memories_json) do
    template
    |> String.replace("{{memory_json}}", memory_json)
    |> String.replace("{{existing_memories_json}}", existing_memories_json)
  end
end
