defmodule Acs.MCP.UrlSafety do
  @moduledoc """
  Validates outbound HTTP URLs to reduce SSRF risk for Bridge and dynamic tools.
  """

  @private_ipv4_prefixes [
    {127, 0, 0, 0, 8},
    {10, 0, 0, 0, 8},
    {172, 16, 0, 0, 12},
    {192, 168, 0, 0, 16},
    {169, 254, 0, 0, 16},
    {0, 0, 0, 0, 8}
  ]

  @blocked_hostnames ~w(
    localhost
    metadata.google.internal
    metadata
  )

  @doc """
  Validates a URL before making an outbound HTTP request.

  Returns `:ok` or `{:error, reason}`.
  """
  def validate_outbound_url(url) when is_binary(url) do
    with {:ok, uri} <- parse_uri(url),
         :ok <- scheme_allowed?(uri),
         :ok <- host_allowed?(uri.host) do
      :ok
    end
  end

  def validate_outbound_url(_), do: {:error, "URL must be a string"}

  defp parse_uri(url) do
    uri = URI.parse(String.trim(url))

    if uri.scheme in ~w(http https) and is_binary(uri.host) and uri.host != "" do
      {:ok, uri}
    else
      {:error, "URL must be an absolute http(s) URL with a host"}
    end
  end

  defp scheme_allowed?(%URI{scheme: scheme}) when scheme in ~w(http https), do: :ok
  defp scheme_allowed?(_), do: {:error, "Only http and https URLs are allowed"}

  defp host_allowed?(host) do
    normalized = String.downcase(host)

    cond do
      normalized in @blocked_hostnames ->
        {:error, "Host '#{host}' is not allowed"}

      normalized == "169.254.169.254" ->
        {:error, "Cloud metadata endpoints are not allowed"}

      ip_address?(normalized) ->
        validate_ip_literal(normalized)

      true ->
        validate_resolved_host(normalized)
    end
  end

  defp ip_address?(host) do
    match?({:ok, _}, :inet.parse_address(String.to_charlist(host)))
  end

  defp validate_ip_literal(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        if private_ip?(ip), do: {:error, "Private or loopback IP addresses are not allowed"}, else: :ok

      {:error, _} ->
        {:error, "Invalid IP address '#{host}'"}
    end
  end

  defp validate_resolved_host(host) do
    allowlist = Application.get_env(:steward_acs, :bridge_allowed_hosts, [])

    if allowlist != [] do
      if host_in_allowlist?(host, allowlist) do
        :ok
      else
        {:error, "Host '#{host}' is not in BRIDGE_ALLOWED_HOSTS"}
      end
    else
      cond do
        String.ends_with?(host, ".local") or String.ends_with?(host, ".internal") ->
          {:error, "Internal hostnames are not allowed"}

        true ->
          resolve_host_ips(host)
      end
    end
  end

  defp host_in_allowlist?(host, allowlist) do
    Enum.any?(allowlist, fn allowed ->
      allowed = String.downcase(allowed)
      host == allowed or String.ends_with?(host, "." <> allowed)
    end)
  end

  defp resolve_host_ips(host) do
    ips =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddr(String.to_charlist(host), family) do
          {:ok, ip} -> [ip]
          {:error, _} -> []
        end
      end)

    cond do
      ips == [] ->
        {:error, "Could not resolve host '#{host}'"}

      Enum.any?(ips, &private_ip?/1) ->
        {:error, "Host '#{host}' resolves to a private or loopback address"}

      true ->
        :ok
    end
  end

  defp private_ip?({a, b, c, d}) do
    Enum.any?(@private_ipv4_prefixes, fn {prefix_a, prefix_b, prefix_c, prefix_d, bits} ->
      ip_in_cidr?({a, b, c, d}, {prefix_a, prefix_b, prefix_c, prefix_d}, bits)
    end)
  end

  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true

  defp private_ip?({a, _, _, _, _, _, _, _}) do
    Bitwise.band(a, 0xFE00) == 0xFC00 or Bitwise.band(a, 0xFFC0) == 0xFE80
  end

  defp ip_in_cidr?({a, b, c, d}, {pa, pb, pc, pd}, bits) when bits <= 32 do
    ip_int = Bitwise.bsl(a, 24) + Bitwise.bsl(b, 16) + Bitwise.bsl(c, 8) + d
    prefix_int = Bitwise.bsl(pa, 24) + Bitwise.bsl(pb, 16) + Bitwise.bsl(pc, 8) + pd
    mask = Bitwise.bsl(0xFFFFFFFF, 32 - bits)
    Bitwise.band(ip_int, mask) == Bitwise.band(prefix_int, mask)
  end

  defp private_ip?(_), do: false
end
