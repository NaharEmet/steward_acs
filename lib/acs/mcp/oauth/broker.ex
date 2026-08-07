defmodule Acs.MCP.OAuth.Broker do
  @moduledoc """
  OAuth broker that lets ANY MCP client authenticate without per-software
  Auth0 callback registration.

  Auth0 only supports subdomain wildcards for callbacks and requires exact
  URLs for third-party apps, so direct `/authorize` + `/token` forwarding
  (Caddy → Auth0) forced every connector's callback URI to be allowlisted.

  Instead, ACS serves `/authorize`, `/oauth/callback`, and `/token` itself:

    * `/authorize` — accepts ANY loopback or https `redirect_uri`, stores a
      server-side session (client redirect URI, original state, broker PKCE
      verifier), and redirects the browser to Auth0 with a SINGLE fixed
      callback (`https://{host}/oauth/callback`) — the only URI registered in
      Auth0.
    * `/oauth/callback` — Auth0 returns the code here; the broker re-binds it
      to the client's session and redirects the browser back to the client's
      original `redirect_uri` with `code` + the client's original `state`.
    * `/token` — the client exchanges its code here; the broker validates the
      code against its session, performs the Auth0 exchange server-side using
      the fixed callback + broker PKCE verifier, and relays the token response.

  Result: any MCP client (Codex, Cursor, Claude, ChatGPT, future ones) works
  with zero Auth0 config. Tokens are still Auth0 JWTs validated by
  `Acs.MCP.OAuth.JWKS` (issuer/audience checks unchanged).
  """

  import Plug.Conn

  alias Acs.MCP.OAuth.{BrokerStore, Config}

  @behaviour Plug

  @broker_callback_path "/oauth/callback"

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    conn = fetch_query_params(conn)

    cond do
      not Config.enabled?() ->
        not_enabled(conn)

      String.starts_with?(conn.request_path, "/authorize") ->
        handle_authorize(conn)

      conn.request_path == @broker_callback_path ->
        handle_callback(conn)

      conn.request_path == "/token" and conn.method == "POST" ->
        handle_token(conn)

      true ->
        conn
    end
  end

  defp handle_authorize(conn) do
    params = conn.params
    client_redirect_uri = params["redirect_uri"]
    client_state = params["state"] || ""

    cond do
      not valid_redirect_uri?(client_redirect_uri) ->
        invalid_request(conn, "redirect_uri is not an allowed loopback or https URI")

      true ->
        state = generate_state()
        {code_verifier, code_challenge} = pkce_pair()
        client_id = params["client_id"] || Config.fixed_dcr_client_id()

        BrokerStore.put(state, %{
          client_redirect_uri: client_redirect_uri,
          client_state: client_state,
          code_verifier: code_verifier,
          client_id: client_id
        })

        auth0_url =
          authorize_url(conn, params, client_id, state, code_challenge)

        conn
        |> put_resp_header("location", auth0_url)
        |> send_resp(302, "")
        |> halt()
    end
  end

  defp handle_callback(conn) do
    params = conn.params
    code = params["code"]
    state = params["state"]

    with true <- is_binary(code) and code != "",
         true <- is_binary(state) and state != "",
         session when not is_nil(session) <- BrokerStore.get(state) do
      BrokerStore.put_code(code, state)

      redirect =
        client_redirect(
          session.client_redirect_uri,
          code,
          session.client_state,
          params["session_state"]
        )

      conn
      |> put_resp_header("location", redirect)
      |> send_resp(302, "")
      |> halt()
    else
      _ -> invalid_request(conn, "invalid state")
    end
  end

  defp handle_token(conn) do
    params = conn.params

    case params["grant_type"] do
      "authorization_code" -> handle_auth_code_exchange(conn, params)
      "refresh_token" -> handle_refresh(conn, params)
      _ -> token_error(conn, "unsupported_grant_type", "grant_type must be authorization_code or refresh_token")
    end
  end

  defp handle_auth_code_exchange(conn, params) do
    code = params["code"]
    requested_redirect = params["redirect_uri"]

    with true <- is_binary(code) and code != "",
         session when not is_nil(session) <- BrokerStore.get_by_code(code),
         true <- session.client_redirect_uri == requested_redirect do
      body = %{
        "grant_type" => "authorization_code",
        "code" => code,
        "redirect_uri" => broker_callback_url(conn),
        "client_id" => session.client_id || Config.fixed_dcr_client_id(),
        "code_verifier" => session.code_verifier
      }

      forward_token_request(conn, body)
    else
      _ -> token_error(conn, "invalid_grant", "unknown code or redirect_uri mismatch")
    end
  end

  defp handle_refresh(conn, params) do
    refresh_token = params["refresh_token"]

    if is_binary(refresh_token) and refresh_token != "" do
      body = %{
        "grant_type" => "refresh_token",
        "refresh_token" => refresh_token,
        "client_id" => params["client_id"] || Config.fixed_dcr_client_id()
      }

      forward_token_request(conn, body)
    else
      token_error(conn, "invalid_request", "refresh_token is required")
    end
  end

  defp forward_token_request(conn, body) do
    url = "#{Config.issuer()}/oauth/token"

    case request_fun().(url, body) do
      {:ok, status, response_body} when status in 200..299 ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, encode_body(response_body))
        |> halt()

      {:ok, status, response_body} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(status, encode_body(response_body))
        |> halt()

      {:error, reason} ->
        token_error(conn, "temporarily_unavailable", "token exchange failed: #{inspect(reason)}")
    end
  end

  defp encode_body(body) when is_binary(body), do: body
  defp encode_body(body) when is_map(body), do: Jason.encode!(body)

  defp request_fun do
    case Application.get_env(:steward_acs, :oauth_broker_request_fun) do
      fun when is_function(fun, 2) -> fun
      _ -> &req_post/2
    end
  end

  defp req_post(url, body) do
    case Req.post(url, form: body, receive_timeout: 30_000) do
      {:ok, %{status: status, body: response_body}} ->
        {:ok, status, response_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Builds the Auth0 authorize URL. Keeps the client's own params (connection,
  # login_hint, prompt, ...) but overrides everything that must be broker-owned:
  # client_id, redirect_uri, state, code_challenge, audience.
  defp authorize_url(conn, params, client_id, broker_state, code_challenge) do
    overridden = [
      "client_id",
      "redirect_uri",
      "state",
      "response_type",
      "code_challenge",
      "code_challenge_method",
      "audience",
      "resource"
    ]

    query =
      params
      |> Map.drop(overridden)
      |> Map.put("client_id", client_id)
      |> Map.put("redirect_uri", broker_callback_url(conn))
      |> Map.put("state", broker_state)
      |> Map.put("code_challenge", code_challenge)
      |> Map.put("code_challenge_method", "S256")
      |> Map.put("audience", Config.resource_url_for_host(conn.host))
      |> Map.put_new("response_type", "code")
      |> Map.put_new("scope", "mcp:tools")

    "#{Config.issuer()}/authorize?#{URI.encode_query(query)}"
  end

  defp broker_callback_url(conn) do
    host =
      if is_binary(conn.host) and conn.host != "" do
        conn.host
      else
        "localhost"
      end

    "https://#{host}#{@broker_callback_path}"
  end

  defp client_redirect(client_uri, code, client_state, session_state) do
    sep = if URI.parse(client_uri).query, do: "&", else: "?"

    query = [{"code", code}, {"state", client_state}] ++
      if is_binary(session_state) and session_state != "", do: [{"session_state", session_state}], else: []

    client_uri <> sep <> URI.encode_query(query)
  end

  # Loopback (http) or https only. Rejects http:// to arbitrary hosts (open
  # redirect) and non-http schemes.
  defp valid_redirect_uri?(uri) when is_binary(uri) and uri != "" do
    case URI.parse(uri) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> true
      %URI{scheme: "http", host: host} -> host in ["localhost", "127.0.0.1", "0.0.0.0", "::1", "[::1]"]
      _ -> false
    end
  end

  defp valid_redirect_uri?(_), do: false

  defp generate_state do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end

  defp pkce_pair do
    verifier = :crypto.strong_rand_bytes(48) |> Base.url_encode64(padding: false)
    challenge = :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
    {verifier, challenge}
  end

  defp not_enabled(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(503, Jason.encode!(%{error: "oauth_broker_disabled"}))
    |> halt()
  end

  defp invalid_request(conn, description) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{error: "invalid_request", error_description: description}))
    |> halt()
  end

  defp token_error(conn, error, description) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(400, Jason.encode!(%{error: error, error_description: description}))
    |> halt()
  end
end
