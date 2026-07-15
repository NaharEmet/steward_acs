defmodule Acs.ConfigEnv do
  @moduledoc false

  @doc """
  Parses `ACS_ORG_DASHBOARD_CREDS` JSON into `%{org => %{username: ..., password: ...}}`.
  Nil, empty, or whitespace-only input returns `%{}`.
  """
  def parse_org_dashboard_creds(nil), do: %{}
  def parse_org_dashboard_creds(""), do: %{}

  def parse_org_dashboard_creds(creds) when is_binary(creds) do
    case String.trim(creds) do
      "" -> %{}
      trimmed -> decode_org_dashboard_creds(trimmed)
    end
  end

  defp decode_org_dashboard_creds(json) do
    case Jason.decode(json) do
      {:ok, orgs} when is_map(orgs) ->
        Enum.reduce(orgs, %{}, fn {org, entry}, acc ->
          case entry do
            %{"username" => username, "password" => password}
            when is_binary(org) and is_binary(username) and is_binary(password) ->
              Map.put(acc, org, %{username: username, password: password})

            _ ->
              raise ArgumentError,
                    "ACS_ORG_DASHBOARD_CREDS entry #{inspect(org)} must be a JSON object " <>
                      "with string \"username\" and \"password\" keys"
          end
        end)

      {:ok, _} ->
        raise ArgumentError,
              "ACS_ORG_DASHBOARD_CREDS must be a JSON object mapping org slugs to credentials"

      {:error, %Jason.DecodeError{} = error} ->
        raise ArgumentError, "ACS_ORG_DASHBOARD_CREDS is not valid JSON: #{Exception.message(error)}"
    end
  end
end
