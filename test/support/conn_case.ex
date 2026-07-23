defmodule AcsWeb.ConnCase do
  @moduledoc """
  Test case template for tests that need a connection and database access.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint AcsWeb.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      alias Acs.Repo
    end
  end

  setup tags do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Acs.Repo)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Acs.Repo, {:shared, self()})
    end

    %{conn: Phoenix.ConnTest.build_conn()}
  end
end
