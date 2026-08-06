defmodule Acs.Auth0.Management do
  @moduledoc false

  @doc "Management API config when multi-tenant + AUTH0_MGMT_* are set."
  @spec config() :: {:ok, map()} | {:error, atom()}
  def config do
    domain = Application.get_env(:steward_acs, :auth0_domain) || System.get_env("AUTH0_DOMAIN")
    client_id = Application.get_env(:steward_acs, :auth0_mgmt_client_id)
    client_secret = Application.get_env(:steward_acs, :auth0_mgmt_client_secret)
    base_domain = Application.get_env(:steward_acs, :base_domain) || System.get_env("BASE_DOMAIN")

    cond do
      not Acs.Org.multi_tenant?() ->
        {:error, :not_multi_tenant}

      blank?(domain) or blank?(client_id) or blank?(client_secret) ->
        {:error, :mgmt_not_configured}

      true ->
        {:ok,
         %{
           domain: String.trim_trailing(domain, "/"),
           client_id: client_id,
           client_secret: client_secret,
           base_domain: base_domain
         }}
    end
  end

  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _}, config())

  @spec token(map()) :: {:ok, String.t()} | {:error, term()}
  def token(cfg) do
    url = "https://#{cfg.domain}/oauth/token"

    body = %{
      client_id: cfg.client_id,
      client_secret: cfg.client_secret,
      audience: "https://#{cfg.domain}/api/v2/",
      grant_type: "client_credentials"
    }

    case Req.post(url, json: body, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"access_token" => token}}} when is_binary(token) ->
        {:ok, token}

      {:ok, %{status: status, body: body}} ->
        {:error, {:token_http, status, body}}

      {:error, reason} ->
        {:error, {:token_request, reason}}
    end
  end

  def get(cfg, token, path), do: req_json(:get, "https://#{cfg.domain}#{path}", token)

  def post(cfg, token, path, body),
    do: req_json(:post, "https://#{cfg.domain}#{path}", token, body)

  def patch(cfg, token, path, body),
    do: req_json(:patch, "https://#{cfg.domain}#{path}", token, body)

  defp req_json(method, url, token, body \\ nil) do
    opts = [headers: [{"authorization", "Bearer #{token}"}], receive_timeout: 20_000]

    result =
      case {method, body} do
        {:get, _} -> Req.get(url, opts)
        {:post, body} -> Req.post(url, Keyword.put(opts, :json, body))
        {:patch, body} -> Req.patch(url, Keyword.put(opts, :json, body))
      end

    case result do
      {:ok, %{status: status, body: resp}} when status in 200..299 ->
        {:ok, resp}

      {:ok, %{status: status, body: resp}} ->
        {:error, {:http, status, resp}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp blank?(v), do: not is_binary(v) or String.trim(v) == ""
end
