import Config

# Load .env file at runtime for all environments
# Must happen before any OTP apps start for ENCRYPTION_KEY
if File.exists?(".env") do
  File.read!(".env")
  |> String.split("\n")
  |> Enum.each(fn line ->
    line = String.trim(line)

    if String.length(line) > 0 and not String.starts_with?(line, "#") do
      case String.split(line, "=", parts: 2) do
        [key, value] ->
          System.put_env(String.trim(key), String.trim(value))

        _ ->
          :ok
      end
    end
  end)
end

# Auditor polling interval (default: 30 seconds)
config :steward_acs, :auditor_interval,
  System.get_env("AUDITOR_INTERVAL", "30000") |> String.to_integer()

# If DATABASE_URL is set, configure connection
if System.get_env("DATABASE_URL") do
  config :steward_acs, Acs.Repo,
    url: System.get_env("DATABASE_URL"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE", "10"))
end

# MIMO API key — primary LLM provider for memory evaluation
config :steward_acs, :mimo_api_key, System.get_env("MIMO_API_KEY", "")

# Enabled LLM providers — whitelist of provider IDs to use.
# If empty or not set, all providers with configured API keys are tried.
# Example: ENABLED_LLM_PROVIDERS=mimo  (only MIMO)
#          ENABLED_LLM_PROVIDERS=mimo,minimax  (MIMO + MiniMax)
config :steward_acs,
       :enabled_llm_providers,
       System.get_env("ENABLED_LLM_PROVIDERS", "")
       |> String.split(",", trim: true)
       |> Enum.map(&String.trim/1)

# Ollama URL for local embedding generation
config :steward_acs, Acs.Memory.Embedding,
  ollama_url: System.get_env("OLLAMA_URL", "http://localhost:11434")

# Cluster identity — scopes all ACS operations
config :steward_acs, :cluster_name, System.get_env("ACS_CLUSTER_NAME", "default")

# Developer identity — used to tag memory creation
config :steward_acs,
       :developer_name,
       System.get_env("ACS_DEVELOPER_NAME", "unknown")
