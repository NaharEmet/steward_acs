defmodule Acs.Org do
  require Logger

  @moduledoc """
  Org identity and filtering context for multi-tenancy.

  Each request is scoped to an org derived from the URL subdomain
  (`orgname.stewardacs.xyz` or `orgname.obsidian.stewardacs.xyz`).

  `put_request_org/1` is set by `AcsWeb.Plugs.ResolveOrg` so that
  `current/0` returns the request org during HTTP handling.
  """

  @request_org_key :acs_request_org
  @obsidian_label "obsidian"
  @org_slug_regex ~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/

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
      if previous,
        do: Process.put(@request_org_key, previous),
        else: Process.delete(@request_org_key)
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
  Returns the configured Obsidian vault base, or `nil` when no vault is configured.
  """
  def vault_base do
    case Application.get_env(:steward_acs, :obsidian_vault_path) do
      base when is_binary(base) and base != "" -> Path.expand(base)
      _ -> nil
    end
  end

  @doc """
  Returns an org's canonical vault root: `<vault>/orgs/<slug>`.
  """
  def org_vault_root(org \\ current()) when is_binary(org) do
    org = validate_slug!(org)

    case vault_base() do
      nil -> nil
      base -> Path.join([base, "orgs", org])
    end
  end

  @doc """
  Returns whether a value is a valid organization slug for vault paths.
  """
  def valid_slug?(org) when is_binary(org), do: Regex.match?(@org_slug_regex, org)
  def valid_slug?(_), do: false

  @doc """
  Returns the canonical memory directory for an org.
  """
  def memory_dir(org \\ current()) when is_binary(org) do
    artifact_dir(org, "private/memories", fn -> fallback_org_dir("priv/acs_memory", org) end)
  end

  def skills_dir(org \\ current()) when is_binary(org) do
    artifact_dir(org, "skills", fn -> fallback_org_dir("priv/skills", org) end)
  end

  def specs_dir(org \\ current()) when is_binary(org) do
    artifact_dir(org, "specs", fn -> fallback_org_dir("../../../acs/specs", org) end)
  end

  def prompts_dir(org \\ current()) when is_binary(org) do
    artifact_dir(org, "prompts", fn -> fallback_org_dir("priv/prompts", org) end)
  end

  def tools_dir(org \\ current()) when is_binary(org) do
    artifact_dir(org, "acstools", fn -> fallback_org_dir("../../../acs/acstools", org) end)
  end

  @doc """
  Returns the configured org's pre-canonical memory directory, if any.
  """
  def legacy_memory_dir(org \\ current()) when is_binary(org) do
    org = validate_slug!(org)

    if org == configured() do
      case vault_base() do
        nil -> Path.join(Application.app_dir(:steward_acs), "priv/acs_memory")
        base -> Path.join(base, "private/memories")
      end
    end
  end

  def legacy_skills_dir(org \\ current()), do: legacy_skills_dirs(org) |> List.first()
  def legacy_specs_dir(org \\ current()), do: legacy_specs_dirs(org) |> List.first()
  def legacy_prompts_dir(org \\ current()), do: legacy_prompts_dirs(org) |> List.first()
  def legacy_tools_dir(_org \\ current()), do: nil

  def legacy_memory_dirs(org \\ current()), do: List.wrap(legacy_memory_dir(org))

  def legacy_skills_dirs(org \\ current()) when is_binary(org),
    do: legacy_partitioned_dirs(org, "skills")

  def legacy_specs_dirs(org \\ current()) when is_binary(org),
    do: legacy_partitioned_dirs(org, "specs")

  def legacy_prompts_dirs(org \\ current()) when is_binary(org) do
    org = validate_slug!(org)

    if vault_base() do
      if multi_tenant?(),
        do: [Path.join([vault_base(), org, "prompts"])],
        else: if(org == configured(), do: [Path.join(vault_base(), "prompts")], else: [])
    else
      []
    end
  end

  def legacy_tools_dirs(_org \\ current()), do: []

  @doc """
  Returns the vault base when configured, or the active memory directory otherwise.
  """
  def vault_watch_root, do: vault_base() || memory_dir()

  @doc """
  Extracts an org slug from a canonical org path or configured-org legacy path.

  Returns `nil` for paths outside those roots or with an invalid slug.
  """
  def org_from_vault_path(path) when is_binary(path) do
    case vault_base() do
      nil ->
        if path_within?(path, legacy_memory_dir(configured())), do: configured(), else: nil

      base ->
        case Path.split(Path.relative_to(Path.expand(path), base)) do
          ["orgs", org | _] ->
            classify_known_org(org)

          [artifact, "orgs", org | _] when artifact in ["skills", "specs"] ->
            classify_known_org(org)

          [org, "prompts" | _] ->
            classify_known_org(org)

          _ ->
            legacy_path_org(path)
        end
    end
  end

  def org_from_vault_path(_), do: nil

  defp classify_known_org(org),
    do: if(valid_slug?(org) and known_org?(org), do: org, else: nil)

  defp artifact_dir(org, artifact, fallback) do
    org = validate_slug!(org)

    case org_vault_root(org) do
      nil -> fallback.()
      root -> Path.join(root, artifact)
    end
  end

  defp legacy_partitioned_dirs(org, artifact) do
    org = validate_slug!(org)

    case vault_base() do
      nil ->
        []

      base ->
        root = Path.join(base, artifact)
        if org == "default", do: [root], else: [Path.join([root, "orgs", org])]
    end
  end

  defp fallback_org_dir(path, org) do
    org = validate_slug!(org)
    base = Path.expand(path, Application.app_dir(:steward_acs))
    Path.join([base, "orgs", org])
  end

  defp legacy_path_org(path) do
    configured_org = configured()

    legacy_roots =
      legacy_memory_dirs(configured_org) ++
        legacy_skills_dirs(configured_org) ++
        legacy_specs_dirs(configured_org) ++ legacy_prompts_dirs(configured_org)

    if Enum.any?(legacy_roots, &path_within?(path, &1)) do
      configured_org
    end
  end

  defp path_within?(path, root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)
    expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/")
  end

  defp validate_slug!(org) do
    if valid_slug?(org),
      do: org,
      else: raise(ArgumentError, "Invalid organization: #{inspect(org)}")
  end

  @doc false
  def known_org?(org) when is_binary(org) do
    cond do
      org == configured() ->
        true

      not multi_tenant?() ->
        org == current()

      true ->
        Acs.Orgs.list_all()
        |> Enum.any?(&(&1.slug == org and &1.provisioning_status == "ready"))
    end
  rescue
    _ -> org == configured()
  end

  def known_org?(_), do: false

  @doc "Returns true when path is lexically contained by root after resolving all symlinks."
  def safe_path?(root, path) when is_binary(root) and is_binary(path) do
    real_root = realpath(root)
    real_path = realpath(path)
    path_within?(real_path, real_root)
  rescue
    _ -> false
  end

  def safe_path?(_, _), do: false

  defp realpath(path) do
    path
    |> Path.expand()
    |> Path.split()
    |> Enum.reduce_while(nil, fn
      "/", _ -> {:cont, "/"}
      segment, nil -> {:cont, segment}
      segment, current ->
        candidate = Path.join(current, segment)
        resolved = case File.lstat(candidate) do
          {:ok, %File.Stat{type: :symlink}} ->
            link = File.read_link!(candidate)
            target = if String.starts_with?(link, "/"), do: link, else: Path.join(Path.dirname(candidate), link)
            Path.expand(target)
          {:ok, _} -> candidate
          {:error, :enoent} -> candidate
          {:error, _} -> candidate
        end
        {:cont, resolved}
    end)
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
