defmodule AcsWeb.Plugs.LocalhostOnlyTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias AcsWeb.Plugs.LocalhostOnly

  test "allows loopback requests" do
    conn = conn(:get, "/dev/mailbox") |> Map.put(:remote_ip, {127, 0, 0, 1})
    assert %Plug.Conn{halted: false} = LocalhostOnly.call(conn, [])
  end

  test "blocks remote requests" do
    conn = conn(:get, "/dev/mailbox") |> Map.put(:remote_ip, {192, 168, 1, 10})
    assert %Plug.Conn{halted: true, status: 403} = LocalhostOnly.call(conn, [])
  end
end
