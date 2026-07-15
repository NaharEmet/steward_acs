defmodule Acs.Org do
  @moduledoc """
  Org identity and filtering context for multi-tenancy.

  Each request is scoped to an org derived from the URL subdomain
  (`orgname.stewardacs.xyz` or `orgname.obsidian.stewardacs.xyz`).

  `put_request_org/1` is set by `AcsWeb.Plugs.ResolveOrg` so that
  `current/0` returns the request org during HTTP handling.
  """

  @request_org_key :acs_request_org
  @obsidian_label "obsidian"

  @doc """
  Returns the active org slug for the current process.

  Priority: request-scoped org (from URL) → config `:org_name` → `"default"`.
  """
  def current do
    Process.get(@request_org_key) ||
      Application.get_env(:steward_acs, :org_name) ||
      Application.get_env(:steward_acs, :cluster_name, "default")
  end

  @doc """
  Sets the org for the current process (request lifetime).
  Called by `ResolveOrg` after parsing the Host header.
  """
  def put_request_org(org) when is_binary(org) do
    Process.put(@request_org_key, org)
    :ok
  end

  def put_current(org) when is_binary(org) and org != "" do
    Process.put(@request_org_key, org)
    :ok
  end

  def with_current(org, fun) when is_binary(org) and org != "" and is_function(fun, 0) do
    previous = Process.get(@request_org_key)
    put_current(org)

    try do
      fun.()
    after
      if previous, do: Process.put(@request_org_key, previous), else: Process.delete(@request_org_key)
    end
  end

  def clear_request_org do
    Process.delete(@request_org_key)
    :ok
  end

  @doc """
  Returns whether multi-tenant subdomain mode is enabled.
  """
  def multi_tenant? do
    Application.get_env(:steward_acs, :multi_tenant, false) == true
  end

  @doc """
  Returns the org configured for this deployment.

  This org owns the pre-multi-tenant filesystem layout and unqualified IDs.
  """
  def configured do
    Application.get_env(:steward_acs, :org_name) ||
      Application.get_env(:steward_acs, :cluster_name, "default")
  end

  @doc """
  Returns the apex domain for subdomain parsing (e.g. `stewardacs.xyz`).
  """
  def base_domain do
    Application.get_env(:steward_acs, :base_domain) ||
      infer_base_domain_from_host()
  end

  @doc """
  Returns the list of all known org slugs (from DB when multi-tenant).
  """
  def all do
    if multi_tenant?() do
      Acs.Orgs.list_all() |> Enum.map(& &1.slug)
    else
      [current()]
    end
  end

  @doc """
  Returns an Ecto query filter for the current org.
  """
  def filter, do: current()

  @doc """
  Returns the org for the current MCP tool call or HTTP request.

  Prefers `_auth_org_id` from tool args, then request-scoped org, then config.
  """
  def scoped(args \\ %{}) when is_map(args) do
    case Map.get(args, "_auth_org_id") do
      org when is_binary(org) and org != "" -> org
      _ -> current()
    end
  end

  @doc """
  When multi-tenant, returns `{:ok, org}` or applies org to indexer/query opts.
  """
  def indexer_opts(opts \\ []) do
    if multi_tenant?() and not Keyword.has_key?(opts, :org) do
      Keyword.put(opts, :org, current())
    else
      opts
    end
  end

  @doc """
  When multi-tenant, ensures list/count queries include the current org filter.
  """
  def with_org_opts(opts) when is_list(opts) do
    if multi_tenant?() and not Keyword.has_key?(opts, :org) do
      Keyword.put(opts, :org, current())
    else
      opts
    end
  end

  @doc """
  ETS/cache key for multi-tenant isolation. Single-tenant uses `id` only;
  multi-tenant uses `{org, id}`.
  """
  def ets_key(id, org \\ current()) when is_binary(id) and is_binary(org) do
    if multi_tenant?(), do: {org, id}, else: id
  end

  @doc """
  Returns the derived-store ID for a memory.

  The configured org keeps legacy IDs; other tenants are qualified to avoid
  collisions in indexes whose historical primary key is only the memory ID.
  """
  def memory_index_id(id, org \\ current()) when is_binary(id) and is_binary(org) do
    if multi_tenant?() and org != configured(), do: "#{org}:#{id}", else: id
  end

  def public_memory_id(id, org \\ current()) when is_binary(id) and is_binary(org) do
    String.replace_prefix(id, "#{org}:", "")
  end

  @doc """
  Returns true when an existing record's org does not match the current request org.
  """
  def foreign_org?(%{org: record_org}) when is_binary(record_org) do
    multi_tenant?() and record_org != current()
  end

  def foreign_org?(_), do: false

  @doc """
  Extracts the org subdomain label from a full hostname.

  ## Examples

      extract_subdomain("acme.stewardacs.xyz")           # "acme"
      extract_subdomain("acme.obsidian.stewardacs.xyz")  # "acme"
      extract_subdomain("stewardacs.xyz")                # nil (apex → default)
      extract_subdomain("www.stewardacs.xyz")            # nil
  """
  def extract_subdomain(host) when is_binary(host) do
    host = String.downcase(host)
    base = String.downcase(base_domain())

    cond do
      host == base or host == "www." <> base ->
        nil

      String.ends_with?(host, "." <> base) ->
        prefix = String.replace_suffix(host, "." <> base, "")
        parse_subdomain_prefix(prefix)

      true ->
        legacy_extract_subdomain(host)
    end
  end

  def extract_subdomain(_), do: nil

  @doc """
  Resolves an org slug from a subdomain string via `Acs.Orgs.resolve_subdomain/1`.
  """
  def from_subdomain(subdomain) do
    case Acs.Orgs.resolve_subdomain(subdomain) do
      {:ok, slug} -> slug
      {:error, _} -> nil
    end
  end

  @doc """
  Resolves org slug from a hostname, or nil when unknown/invalid.
  """
  def from_host(host) when is_binary(host) do
    host
    |> extract_subdomain()
    |> then(fn
      nil -> from_subdomain(nil)
      subdomain -> from_subdomain(subdomain)
    end)
  end

  def from_host(_), do: nil

  @doc """
  Returns the Obsidian vault directory for an org.

  Configured org: `/vaults/private/memories` (legacy-compatible)
  Additional org: `/vaults/orgs/<org>/private/memories`
  Single-tenant: `<OBSIDIAN_VAULT_PATH>/private/memories` or priv fallback
  """
  def memory_dir(org \\ current()) do
    base = Application.get_env(:steward_acs, :obsidian_vault_path)

    cond do
      multi_tenant?() and is_binary(base) and base != "" and org != configured() ->
        Path.join([base, "orgs", org, "private", "memories"])

      is_binary(base) and base != "" ->
        Path.join(base, "private/memories")

      true ->
        Path.join(Application.app_dir(:steward_acs), "priv/acs_memory")
    end
  end

  @doc """
  Returns the vault root to watch in multi-tenant mode (`/vaults`), or the
  single-org memory dir otherwise.
  """
  def vault_watch_root do
    base = Application.get_env(:steward_acs, :obsidian_vault_path)

    if multi_tenant?() and is_binary(base) and base != "" do
      base
    else
      memory_dir()
    end
  end

  @doc """
  Extracts org slug from a vault file path under the watch root.
  """
  def org_from_vault_path(path) when is_binary(path) do
    base = Application.get_env(:steward_acs, :obsidian_vault_path)

    if multi_tenant?() and is_binary(base) and base != "" do
      case Path.relative_to(path, base) do
        relative when is_binary(relative) ->
          case Path.split(relative) do
            ["orgs", org | _] when org not in ["", ".", ".."] -> org
            _ -> configured()
          end

        _ ->
          configured()
      end
    else
      current()
    end
  end

  def developer_name do
    Application.get_env(:steward_acs, :developer_name, "unknown")
  end

  def project_name do
    Application.get_env(:steward_acs, :project_name, "")
  end

  defp parse_subdomain_prefix(prefix) do
    case String.split(prefix, ".") do
      [org, @obsidian_label] -> org
      [org] -> org
      _ -> nil
    end
  end

  # Fallback when BASE_DOMAIN is unset (local dev): acme.localhost → acme
  defp legacy_extract_subdomain(host) do
    parts = String.split(host, ".")

    case parts do
      [subdomain | _] when subdomain not in ["www", ""] and length(parts) > 2 ->
        subdomain

      _ ->
        nil
    end
  end

  defp infer_base_domain_from_host do
    case Application.get_env(:steward_acs, AcsWeb.Endpoint)[:url][:host] do
      host when is_binary(host) and host != "" ->
        parts = String.split(host, ".")

        if length(parts) >= 2 do
          parts |> Enum.take(-2) |> Enum.join(".")
        else
          host
        end

      _ ->
        "stewardacs.xyz"
    end
  end
end
