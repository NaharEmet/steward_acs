defmodule Acs.Developers do
  @moduledoc """
  Context for managing developer API keys.

  Keys are stored as SHA-256 hashes for fast lookup.
  Raw keys are shown once at creation time and cannot be retrieved.
  """
  alias Acs.Developers.DeveloperApiKey
  alias Acs.Repo
  import Ecto.Query
  require Logger

  @doc """
  Authenticate a developer by raw key.
  Returns `{:ok, %{role: role, cluster: cluster}}` or `{:error, reason}`.
  """
  def authenticate(key) do
    hash = hash_key(key)

    case Repo.get_by(DeveloperApiKey, key_hash: hash, active: true) do
      nil ->
        {:error, "Invalid API key"}

      dev_key ->
        # Update last_used_at (synchronous, fast single-row update)
        Repo.update_all(
          from(d in DeveloperApiKey, where: d.id == ^dev_key.id),
          set: [last_used_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )

        {:ok,
         %{
           role: dev_key.role,
           cluster: dev_key.cluster,
           developer_name: dev_key.developer_name,
           allowed_teams: decode_json(dev_key.allowed_teams_json),
           allowed_projects: decode_json(dev_key.allowed_projects_json)
         }}
    end
  end

  @doc """
  Generate a new developer API key.

  Returns `{:ok, %{key: raw_key, developer: dev}}`.
  The raw key is shown once and cannot be retrieved later.

  Key format: `acs_dev_<64-char-hex-random>`
  """
  def generate_key(name, opts \\ []) do
    role = Keyword.get(opts, :role, "collaborator")
    cluster = Keyword.get(opts, :cluster, "default")
    allowed_teams = Keyword.get(opts, :allowed_teams)
    allowed_projects = Keyword.get(opts, :allowed_projects)

    raw_key = generate_raw_key()
    hash = hash_key(raw_key)
    prefix = String.slice(raw_key, 0, 12)

    case %DeveloperApiKey{}
         |> DeveloperApiKey.changeset(%{
           key_hash: hash,
           key_prefix: prefix,
           developer_name: name,
           role: role,
           cluster: cluster,
           active: true,
           allowed_teams_json: encode_json(allowed_teams),
           allowed_projects_json: encode_json(allowed_projects)
         })
         |> Repo.insert() do
      {:ok, dev} ->
        {:ok, %{key: raw_key, developer: dev}}

      {:error, changeset} ->
        {:error, "Failed to create developer key: #{inspect(changeset.errors)}"}
    end
  end

  @doc """
  List all developers.
  """
  def list_developers do
    Repo.all(DeveloperApiKey)
  end

  @doc """
  Revoke a developer's key by setting active to false.
  """
  def revoke(id) do
    case Repo.get(DeveloperApiKey, id) do
      nil ->
        {:error, :not_found}

      dev ->
        dev
        |> Ecto.Changeset.change(%{active: false})
        |> Repo.update()
    end
  end

  @doc """
  Hash a raw key using SHA-256.
  Returns hex-encoded digest.
  """
  def hash_key(key) do
    :crypto.hash(:sha256, key) |> Base.encode16(case: :lower)
  end

  @key_prefix "acs_dev_"

  defp generate_raw_key do
    @key_prefix <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))
  end

  defp encode_json(nil), do: nil
  defp encode_json(list) when is_list(list), do: Jason.encode!(list)

  defp decode_json(nil), do: nil

  defp decode_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> list
      _ -> nil
    end
  end
end
