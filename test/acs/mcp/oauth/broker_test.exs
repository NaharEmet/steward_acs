defmodule Acs.MCP.OAuth.BrokerTest do
  use ExUnit.Case, async: false

  alias Acs.MCP.OAuth.{Broker, BrokerStore}

  setup do
    original = %{
      oauth: Application.get_env(:steward_acs, :oauth_bearer_enabled),
      domain: Application.get_env(:steward_acs, :auth0_domain),
      audience: Application.get_env(:steward_acs, :auth0_audience),
      client_id: Application.get_env(:steward_acs, :oauth_fixed_dcr_client_id),
      request_fun: Application.get_env(:steward_acs, :oauth_broker_request_fun)
    }

    Application.put_env(:steward_acs, :oauth_bearer_enabled, true)
    Application.put_env(:steward_acs, :auth0_domain, "dev-jw5wgp2b.us.auth0.com")
    Application.put_env(:steward_acs, :auth0_audience, "https://anantha.stewardacs.xyz/mcp/sse")

    Application.put_env(
      :steward_acs,
      :oauth_fixed_dcr_client_id,
      "0Qt3zP1YbyjtVN9zRf2cN7Pt39NhkHp0"
    )

    BrokerStore.clear()

    on_exit(fn ->
      BrokerStore.clear()
      Application.put_env(:steward_acs, :oauth_bearer_enabled, original.oauth)
      Application.put_env(:steward_acs, :auth0_domain, original.domain)
      Application.put_env(:steward_acs, :auth0_audience, original.audience)
      Application.put_env(:steward_acs, :oauth_fixed_dcr_client_id, original.client_id)

      case original.request_fun do
        nil -> Application.delete_env(:steward_acs, :oauth_broker_request_fun)
        fun -> Application.put_env(:steward_acs, :oauth_broker_request_fun, fun)
      end
    end)

    :ok
  end

  defp host_conn(method, path, query) do
    method
    |> Plug.Test.conn(path, query)
    |> Map.put(:host, "anantha.stewardacs.xyz")
  end

  describe "/authorize" do
    test "accepts a loopback redirect_uri and redirects to Auth0 with the broker callback" do
      conn =
        host_conn(:get, "/authorize", %{
          "redirect_uri" => "http://127.0.0.1:19876/mcp/oauth/callback",
          "client_id" => "0Qt3zP1YbyjtVN9zRf2cN7Pt39NhkHp0",
          "response_type" => "code",
          "scope" => "mcp:tools",
          "state" => "client-state-123",
          "code_challenge" => "client-challenge",
          "code_challenge_method" => "S256"
        })
        |> Broker.call([])

      assert conn.status == 302
      location = Plug.Conn.get_resp_header(conn, "location") |> List.first()
      uri = URI.parse(location)

      assert uri.scheme == "https"
      assert uri.host == "dev-jw5wgp2b.us.auth0.com"
      assert uri.path == "/authorize"

      params = URI.decode_query(uri.query)

      # Broker-owned overrides
      assert params["redirect_uri"] == "https://anantha.stewardacs.xyz/oauth/callback"
      assert params["client_id"] == "0Qt3zP1YbyjtVN9zRf2cN7Pt39NhkHp0"
      assert params["audience"] == "https://anantha.stewardacs.xyz/mcp/sse"
      assert params["code_challenge_method"] == "S256"
      assert params["response_type"] == "code"
      assert params["scope"] == "mcp:tools"
      assert params["code_challenge"] != "client-challenge"

      broker_state = params["state"]
      assert is_binary(broker_state) and broker_state != ""

      # Session persisted server-side
      session = BrokerStore.get(broker_state)
      assert session.client_redirect_uri == "http://127.0.0.1:19876/mcp/oauth/callback"
      assert session.client_state == "client-state-123"
      assert is_binary(session.code_verifier) and session.code_verifier != ""
    end

    test "accepts an https redirect_uri (remote clients like Claude/ChatGPT)" do
      conn =
        host_conn(:get, "/authorize", %{
          "redirect_uri" => "https://claude.ai/api/mcp/auth_callback",
          "state" => "s"
        })
        |> Broker.call([])

      assert conn.status == 302
      location = Plug.Conn.get_resp_header(conn, "location") |> List.first()
      assert String.starts_with?(location, "https://dev-jw5wgp2b.us.auth0.com/authorize?")
    end

    test "accepts a random-port random-path loopback callback (Codex style)" do
      conn =
        host_conn(:get, "/authorize", %{
          "redirect_uri" => "http://127.0.0.1:39965/callback/V57lvZdA_ZPg",
          "state" => "s"
        })
        |> Broker.call([])

      assert conn.status == 302
    end

    test "rejects non-loopback http redirect_uri" do
      conn =
        host_conn(:get, "/authorize", %{
          "redirect_uri" => "http://evil.example.com/callback",
          "state" => "s"
        })
        |> Broker.call([])

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "invalid_request"
    end

    test "rejects non-http(s) schemes" do
      conn =
        host_conn(:get, "/authorize", %{
          "redirect_uri" => "javascript:alert(1)",
          "state" => "s"
        })
        |> Broker.call([])

      assert conn.status == 400
    end

    test "returns 503 when oauth broker is disabled" do
      Application.put_env(:steward_acs, :oauth_bearer_enabled, false)

      conn =
        host_conn(:get, "/authorize", %{"redirect_uri" => "http://127.0.0.1:1/cb"})
        |> Broker.call([])

      assert conn.status == 503
    end
  end

  describe "/oauth/callback" do
    test "binds the Auth0 code and redirects the browser back to the client" do
      # Seed a session the way /authorize does
      state = "broker-state-abc"
      code = "auth0-code-xyz"

      BrokerStore.put(state, %{
        client_redirect_uri: "http://127.0.0.1:39965/callback/V57lvZdA_ZPg",
        client_state: "client-state-123",
        code_verifier: "verifier",
        client_id: "0Qt3zP1YbyjtVN9zRf2cN7Pt39NhkHp0"
      })

      conn =
        host_conn(:get, "/oauth/callback", %{"code" => code, "state" => state})
        |> Broker.call([])

      assert conn.status == 302
      location = Plug.Conn.get_resp_header(conn, "location") |> List.first()

      assert location ==
               "http://127.0.0.1:39965/callback/V57lvZdA_ZPg?code=auth0-code-xyz&state=client-state-123"

      # Code now resolvable server-side for /token
      session = BrokerStore.get_by_code(code)
      assert session.code_verifier == "verifier"
    end

    test "rejects unknown state" do
      conn =
        host_conn(:get, "/oauth/callback", %{"code" => "c", "state" => "nope"})
        |> Broker.call([])

      assert conn.status == 400
    end
  end

  describe "/token" do
    test "exchanges an authorization_code via the broker's fixed callback and PKCE verifier" do
      test_pid = self()
      state = "broker-state-1"
      code = "auth0-code-1"

      BrokerStore.put(state, %{
        client_redirect_uri: "http://127.0.0.1:39965/callback/V57lvZdA_ZPg",
        client_state: "s",
        code_verifier: "broker-verifier-1",
        client_id: "0Qt3zP1YbyjtVN9zRf2cN7Pt39NhkHp0"
      })

      BrokerStore.put_code(code, state)

      Application.put_env(:steward_acs, :oauth_broker_request_fun, fn url, body ->
        send(test_pid, {:token_exchange, url, body})

        {:ok, 200,
         Jason.encode!(%{access_token: "at-1", token_type: "Bearer", expires_in: 86400})}
      end)

      conn =
        host_conn(:post, "/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => "http://127.0.0.1:39965/callback/V57lvZdA_ZPg",
          "client_id" => "0Qt3zP1YbyjtVN9zRf2cN7Pt39NhkHp0"
        })
        |> Broker.call([])

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["access_token"] == "at-1"

      assert_received {:token_exchange, url, exchange_body}

      assert url == "https://dev-jw5wgp2b.us.auth0.com/oauth/token"
      # Broker-owned redirect_uri + verifier, NOT the client's
      assert exchange_body["redirect_uri"] == "https://anantha.stewardacs.xyz/oauth/callback"
      assert exchange_body["code_verifier"] == "broker-verifier-1"
      assert exchange_body["client_id"] == "0Qt3zP1YbyjtVN9zRf2cN7Pt39NhkHp0"
    end

    test "rejects a code whose redirect_uri does not match the session" do
      state = "broker-state-2"
      code = "auth0-code-2"

      BrokerStore.put(state, %{
        client_redirect_uri: "http://127.0.0.1:1111/cb",
        client_state: "s",
        code_verifier: "v",
        client_id: "cid"
      })

      BrokerStore.put_code(code, state)

      conn =
        host_conn(:post, "/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => "http://127.0.0.1:2222/different",
          "client_id" => "cid"
        })
        |> Broker.call([])

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "invalid_grant"
    end

    test "rejects an unknown code" do
      conn =
        host_conn(:post, "/token", %{
          "grant_type" => "authorization_code",
          "code" => "bogus",
          "redirect_uri" => "http://127.0.0.1:39965/callback/V57lvZdA_ZPg",
          "client_id" => "cid"
        })
        |> Broker.call([])

      assert conn.status == 400
    end

    test "forwards a refresh_token grant to Auth0 and relays the response" do
      test_pid = self()

      Application.put_env(:steward_acs, :oauth_broker_request_fun, fn url, body ->
        send(test_pid, {:refresh_exchange, url, body})
        {:ok, 200, Jason.encode!(%{access_token: "at-refresh", refresh_token: "rt-new"})}
      end)

      conn =
        host_conn(:post, "/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => "rt-old",
          "client_id" => "0Qt3zP1YbyjtVN9zRf2cN7Pt39NhkHp0"
        })
        |> Broker.call([])

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["refresh_token"] == "rt-new"

      assert_received {:refresh_exchange, url, exchange_body}
      assert url == "https://dev-jw5wgp2b.us.auth0.com/oauth/token"
      assert exchange_body["grant_type"] == "refresh_token"
      assert exchange_body["refresh_token"] == "rt-old"
    end

    test "rejects unsupported grant types" do
      conn =
        host_conn(:post, "/token", %{"grant_type" => "password"})
        |> Broker.call([])

      assert conn.status == 400
    end

    test "relays upstream error responses from Auth0" do
      Application.put_env(:steward_acs, :oauth_broker_request_fun, fn _url, _body ->
        {:ok, 400, Jason.encode!(%{error: "invalid_grant", error_description: "code expired"})}
      end)

      state = "broker-state-3"
      code = "auth0-code-3"

      BrokerStore.put(state, %{
        client_redirect_uri: "http://127.0.0.1:39965/callback/V57lvZdA_ZPg",
        client_state: "s",
        code_verifier: "v",
        client_id: "cid"
      })

      BrokerStore.put_code(code, state)

      conn =
        host_conn(:post, "/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => "http://127.0.0.1:39965/callback/V57lvZdA_ZPg",
          "client_id" => "cid"
        })
        |> Broker.call([])

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "invalid_grant"
    end

    test "returns 502-style error when the token exchange fails" do
      Application.put_env(:steward_acs, :oauth_broker_request_fun, fn _url, _body ->
        {:error, :econnrefused}
      end)

      state = "broker-state-4"
      code = "auth0-code-4"

      BrokerStore.put(state, %{
        client_redirect_uri: "http://127.0.0.1:39965/callback/V57lvZdA_ZPg",
        client_state: "s",
        code_verifier: "v",
        client_id: "cid"
      })

      BrokerStore.put_code(code, state)

      conn =
        host_conn(:post, "/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => "http://127.0.0.1:39965/callback/V57lvZdA_ZPg",
          "client_id" => "cid"
        })
        |> Broker.call([])

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "temporarily_unavailable"
    end
  end
end
