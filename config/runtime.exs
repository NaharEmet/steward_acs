import Config

# .env is loaded at application start via Dotenvy (see Acs.Application and ENV_PATH).

secret_key_base =
  System.get_env("SECRET_KEY_BASE") ||
    if config_env() == :prod do
      raise "SECRET_KEY_BASE environment variable is required in production. " <>
              "Generate one with: mix phx.gen.secret"
    else
      :crypto.strong_rand_bytes(64) |> Base.encode64()
    end

signing_salt =
  System.get_env("SESSION_SIGNING_SALT") ||
    :crypto.hash(:sha256, secret_key_base)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)

cookie_signing_salt =
  System.get_env("COOKIE_SIGNING_SALT") ||
    :crypto.hash(:sha256, signing_salt <> "cookie")
    |> Base.url_encode64(padding: false)
    |> binary_part(0, 16)

config :steward_acs, AcsWeb.Endpoint,
  secret_key_base: secret_key_base,
  live_view: [signing_salt: signing_salt]

config :steward_acs, :session_signing_salt, cookie_signing_salt

config :steward_acs,
       :auditor_interval,
       System.get_env("AUDITOR_INTERVAL", "30000") |> String.to_integer()

config :steward_acs,
       :session_validity_in_days,
       System.get_env("SESSION_VALIDITY_DAYS", "7") |> String.to_integer()

if System.get_env("DATABASE_URL") do
  config :steward_acs, Acs.Repo,
    url: System.get_env("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
end

if config_env() == :prod do
  cond do
    System.get_env("DATABASE_PATH") ->
      :ok

    url = System.get_env("DATABASE_URL") ->
      if String.contains?(url, "://postgres:postgres@") do
        raise "DATABASE_URL must not use the default postgres password in production"
      end

    System.get_env("PGPASSWORD", "postgres") == "postgres" ->
      raise "PGPASSWORD must not be the default 'postgres' in production"

    true ->
      raise "DATABASE_URL or DATABASE_PATH must be set in production"
  end

  if System.get_env("MCP_API_KEY", "") == "" do
    raise "MCP_API_KEY environment variable is required in production"
  end
end

if System.get_env("DATABASE_PATH") do
  config :steward_acs, :repo_adapter, Ecto.Adapters.SQLite3

  config :steward_acs, Acs.Repo,
    database: System.get_env("DATABASE_PATH"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "5"))
end

if System.get_env("BRIDGE_ALLOWED_HOSTS") do
  config :steward_acs,
         :bridge_allowed_hosts,
         System.get_env("BRIDGE_ALLOWED_HOSTS")
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
         |> Enum.reject(&(&1 == ""))
end

if mcp_api_key = System.get_env("MCP_API_KEY") do
  config :steward_acs, :mcp_api_key, mcp_api_key
end

if service_api_key = System.get_env("SERVICE_API_KEY") do
  config :steward_acs, :service_api_key, service_api_key
end

if log_ingest_key = System.get_env("LOG_INGEST_KEY") do
  config :steward_acs, :log_ingest_key, log_ingest_key
end

if System.get_env("MCP_AUTH_LOCAL_FALLBACK") do
  config :steward_acs,
         :mcp_auth_local_fallback,
         System.get_env("MCP_AUTH_LOCAL_FALLBACK") == "true"
end

if System.get_env("MCP_QUERY_KEY_AUTH") do
  config :steward_acs,
         :mcp_query_key_auth,
         System.get_env("MCP_QUERY_KEY_AUTH") == "true"
end

if System.get_env("OAUTH_BEARER_ENABLED") == "true" do
  config :steward_acs,
         :oauth_bearer_enabled,
         true

  config :steward_acs, :auth_strategies, [
    Acs.MCP.Plugs.Strategies.Developer,
    Acs.MCP.Plugs.Strategies.OAuthBearer,
    Acs.MCP.Plugs.Strategies.Default
  ]
end

if auth0_domain = System.get_env("AUTH0_DOMAIN") do
  config :steward_acs, :auth0_domain, auth0_domain
end

if auth0_audience = System.get_env("AUTH0_AUDIENCE") do
  config :steward_acs, :auth0_audience, auth0_audience
end

if auth0_issuer = System.get_env("AUTH0_ISSUER") do
  config :steward_acs, :auth0_issuer, auth0_issuer
end

if mgmt_client_id = System.get_env("AUTH0_MGMT_CLIENT_ID") do
  config :steward_acs, :auth0_mgmt_client_id, mgmt_client_id
end

if mgmt_client_secret = System.get_env("AUTH0_MGMT_CLIENT_SECRET") do
  config :steward_acs, :auth0_mgmt_client_secret, mgmt_client_secret
end

if connection = System.get_env("AUTH0_CONNECTION") do
  config :steward_acs, :auth0_connection, connection
end

if mcp_public_url = System.get_env("MCP_PUBLIC_URL") do
  config :steward_acs, :mcp_public_url, mcp_public_url
end

if mcp_resource_url = System.get_env("MCP_RESOURCE_URL") do
  config :steward_acs, :mcp_resource_url, mcp_resource_url
end

if System.get_env("HTTP_SLEEP_MAX_MS") do
  config :steward_acs, :http_sleep_max_ms, String.to_integer(System.get_env("HTTP_SLEEP_MAX_MS"))
end

if admin_emails_env = System.get_env("ACS_ADMIN_EMAILS") do
  admin_emails =
    admin_emails_env
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  config :steward_acs, :admin_emails, admin_emails
end

if System.get_env("ALLOWED_PATHS") do
  config :steward_acs,
         :allowed_paths,
         System.get_env("ALLOWED_PATHS")
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
end

if System.get_env("ALLOWED_COMMANDS") do
  config :steward_acs,
         :allowed_commands,
         System.get_env("ALLOWED_COMMANDS")
         |> String.split(",", trim: true)
         |> Enum.map(&String.trim/1)
end

config :steward_acs, :nim_api_key, System.get_env("NIM_API_KEY", "")
config :steward_acs, :mimo_api_key, System.get_env("MIMO_API_KEY", "")
config :steward_acs, :minimax_api_key, System.get_env("MINIMAX_API_KEY", "")
config :steward_acs, :openai_api_key, System.get_env("OPENAI_API_KEY", "")
config :steward_acs, :openai_base_url, System.get_env("OPENAI_BASE_URL", "")
config :steward_acs, :openai_model, System.get_env("OPENAI_MODEL", "")

config :steward_acs,
       :enabled_llm_providers,
       System.get_env("ENABLED_LLM_PROVIDERS", "")
       |> String.split(",", trim: true)
       |> Enum.map(&String.trim/1)

# ─── Memory Evaluation Prompt (file path) ──────────────────────────────
# If set, loads the LLM evaluation prompt from a file (supports {{memory_json}}
# and {{existing_memories_json}} template variables). Falls back to hardcoded default.
if prompt_path = System.get_env("MEMORY_EVALUATION_PROMPT_PATH") do
  config :steward_acs, :memory_evaluation_prompt_path, prompt_path
end

# ─── Memory Auditor Pre-filter Configuration ───────────────────────────
# Lists of comma-separated patterns for auto-reject pre-filter rules.
if prefixes = System.get_env("AUDITOR_REJECT_TITLE_PREFIXES") do
  config :steward_acs, :auditor_reject_title_prefixes,
    String.split(prefixes, ",", trim: true) |> Enum.map(&String.trim/1)
end

if exact = System.get_env("AUDITOR_REJECT_TITLE_EXACT") do
  config :steward_acs, :auditor_reject_title_exact,
    String.split(exact, ",", trim: true) |> Enum.map(&String.trim/1)
end

if scopes = System.get_env("AUDITOR_REJECT_SCOPE_PREFIXES") do
  config :steward_acs, :auditor_reject_scope_prefixes,
    String.split(scopes, ",", trim: true) |> Enum.map(&String.trim/1)
end

if id_prefixes = System.get_env("AUDITOR_REJECT_ID_PREFIXES") do
  config :steward_acs, :auditor_reject_id_prefixes,
    String.split(id_prefixes, ",", trim: true) |> Enum.map(&String.trim/1)
end

if id_contains = System.get_env("AUDITOR_REJECT_ID_CONTAINS") do
  config :steward_acs, :auditor_reject_id_contains,
    String.split(id_contains, ",", trim: true) |> Enum.map(&String.trim/1)
end

if min_len = System.get_env("AUDITOR_MIN_CONTENT_LENGTH") do
  config :steward_acs, :auditor_min_content_length, String.to_integer(min_len)
end

if low_len = System.get_env("AUDITOR_LOW_CONTENT_LENGTH") do
  config :steward_acs, :auditor_low_content_length, String.to_integer(low_len)
end

if threshold = System.get_env("AUDITOR_FUZZY_THRESHOLD") do
  config :steward_acs, :auditor_fuzzy_threshold, String.to_float(threshold)
end

if System.get_env("AUDITOR_REJECT_EMPTY_SCOPE") do
  config :steward_acs, :auditor_reject_empty_scope,
    System.get_env("AUDITOR_REJECT_EMPTY_SCOPE") == "true"
end

if System.get_env("AUDITOR_REJECT_TITLE_EQUALS_CONTENT") do
  config :steward_acs, :auditor_reject_title_equals_content,
    System.get_env("AUDITOR_REJECT_TITLE_EQUALS_CONTENT") == "true"
end

config :steward_acs, Acs.Memory.Embedding,
  ollama_url: System.get_env("OLLAMA_URL", "http://localhost:11434")

config :steward_acs, :org_name,
  System.get_env("ACS_ORG_NAME") || System.get_env("ACS_CLUSTER_NAME", "default")

config :steward_acs, :multi_tenant, System.get_env("MULTI_TENANT", "false") == "true"

config :steward_acs, :project_name, System.get_env("ACS_PROJECT_NAME", "")

config :steward_acs,
       :developer_name,
       System.get_env("ACS_DEVELOPER_NAME", "unknown")

config :steward_acs, :memory_store, System.get_env("MEMORY_STORE", "yaml")

if obsidian_path = System.get_env("OBSIDIAN_VAULT_PATH") do
  config :steward_acs, :obsidian_vault_path, obsidian_path
end

config :steward_acs, :basic_auth,
  username: System.get_env("ACS_USERNAME", "admin"),
  password: System.get_env("ACS_PASSWORD", "admin")

if config_env() == :prod and System.get_env("ACS_PASSWORD", "admin") == "admin" do
  raise "ACS_PASSWORD must not be the default 'admin' in production"
end

if config_env() == :prod do
  host =
    case System.get_env("PHX_HOST") do
      nil -> System.get_env("DOMAIN")
      "" -> System.get_env("DOMAIN")
      value -> value
    end

  if is_nil(host) or host == "" do
    raise "PHX_HOST or DOMAIN environment variable is required in production"
  end

  config :steward_acs, AcsWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    check_origin: ["https://#{host}", "http://#{host}"]
end

if origins = System.get_env("CORS_ORIGINS") do
  config :cors_plug,
    origin:
      origins
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
end
