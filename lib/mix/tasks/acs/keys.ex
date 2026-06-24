defmodule Mix.Tasks.Acs.Keys do
  use Mix.Task

  @shortdoc "Manage ACS developer API keys"

  @impl true
  def run(args) do
    parsed =
      OptionParser.parse!(args,
        strict: [
          name: :string,
          role: :string,
          cluster: :string,
          id: :string
        ]
      )

    opts = elem(parsed, 0)
    positional = elem(parsed, 1)

    case positional do
      ["generate"] -> generate(opts)
      ["list"] -> list()
      ["revoke"] -> revoke(opts[:id])
      _ -> print_help()
    end
  end

  defp generate(opts) do
    name = opts[:name] || "developer"
    role = opts[:role] || "admin"
    cluster = opts[:cluster] || "default"

    # Ensure repo is started
    Mix.Task.run("app.start")

    case Acs.Developers.generate_key(name, role: role, cluster: cluster) do
      {:ok, %{key: raw_key, developer: dev}} ->
        IO.puts("""
        Developer: #{dev.developer_name}
        Role:      #{dev.role}
        Cluster:   #{dev.cluster}
        Key ID:    #{dev.id}
        API Key:   #{raw_key}

        ⚠️  Store this key securely. It will not be shown again.
        """)

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{reason}")
    end
  end

  defp list do
    Mix.Task.run("app.start")

    developers = Acs.Developers.list_developers()

    if developers == [] do
      IO.puts("No developer keys configured.")
    else
      IO.puts(
        "ID                                   Name        Role    Cluster   Active  Last Used"
      )

      IO.puts(
        "──────────────────────────────────    ────────    ──────  ────────  ──────  ─────────"
      )

      for dev <- developers do
        last =
          case dev.last_used_at do
            nil -> "never"
            dt -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
          end

        IO.puts(
          "#{dev.id}  #{String.pad_trailing(dev.developer_name, 10)}  #{String.pad_trailing(dev.role, 6)}  #{String.pad_trailing(dev.cluster, 8)}  #{if dev.active, do: "yes", else: "no "}  #{last}"
        )
      end
    end
  end

  defp revoke(nil), do: IO.puts(:stderr, "Error: --id is required for revoke")

  defp revoke(id) do
    Mix.Task.run("app.start")

    case Acs.Developers.revoke(id) do
      {:ok, dev} ->
        IO.puts("Revoked key for #{dev.developer_name}")

      {:error, :not_found} ->
        IO.puts(:stderr, "Developer not found: #{id}")
    end
  end

  defp print_help do
    IO.puts("""
    Usage:
      mix acs.keys.generate --name <name> [--role admin|service|reader] [--cluster <cluster>]
      mix acs.keys.list
      mix acs.keys.revoke --id <key_id>
    """)
  end
end
