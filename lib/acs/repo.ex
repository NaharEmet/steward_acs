defmodule Acs.Repo do
  @adapter Application.compile_env(
             :steward_acs,
             :repo_adapter,
             Ecto.Adapters.SQLite3
           )

  use Ecto.Repo,
    otp_app: :steward_acs,
    adapter: @adapter
end
