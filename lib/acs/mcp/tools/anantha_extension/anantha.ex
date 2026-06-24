defmodule Acs.MCP.Tools.AnanthaExtension.Anantha do
  @behaviour Acs.MCP.Tools.AnanthaExtension
  require Logger

  @impl true
  def fetch_memory_stats(org_id) do
    case admin_post("/api/tools/memory_stats", %{org_id: org_id}) do
      {:ok, data} -> data
      _ -> %{}
    end
  end

  @impl true
  def fetch_dlq_entries do
    case admin_post("/api/tools/dlq_list") do
      {:ok, %{"entries" => entries}} -> entries
      _ -> []
    end
  end

  @impl true
  def fetch_llm_config do
    %{
      minimax_key:
        Application.get_env(:anantha_os, :minimax_api_key) ||
          System.get_env("MINIMAX_API_KEY"),
      nim_key:
        Application.get_env(:anantha_os, :nim_api_key) ||
          System.get_env("NIM_API_KEY")
    }
  end

  # Inlined from Acs.AnanthaForwarder
  defp admin_post(path, body \\ %{}) do
    base_url = "http://localhost:4000"
    api_key = Application.get_env(:steward_acs, :service_api_key, "dev-service-key")

    url = base_url <> path

    headers = [
      {"authorization", "Bearer #{api_key}"},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    case Req.request(method: :post, url: url, headers: headers, json: body, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: status, body: response_body}} when status in 200..299 ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        Logger.warning("[AnanthaExtension] HTTP #{status} from #{path}: #{inspect(response_body)}")
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        Logger.warning("[AnanthaExtension] Request failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    e ->
      Logger.error("[AnanthaExtension] Error: #{inspect(e)}")
      {:error, inspect(e)}
  end
end
