defmodule AcsWeb.Router do
  use AcsWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :put_root_layout, {AcsWeb.Layouts, :root}
  end

  scope "/", AcsWeb do
    pipe_through :browser

    live_session :acs do
      live "/", AcsLive.Index, :index
      live "/tools", AcsLive.Tools, :index
      live "/tools/requests", AcsLive.ToolRequests, :index
      live "/memories", AcsLive.MemoryLive, :index
      live "/specs", AcsLive.SpecsLive, :index
      live "/error-traces", AcsLive.ErrorTracesLive, :index
    end
  end
end
