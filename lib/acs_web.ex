defmodule AcsWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and liveviews.
  """

  def static_paths, do: ~w(assets)

  def router do
    quote do
      use Phoenix.Router, helpers: false

      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def controller do
    quote do
      use Phoenix.Controller, formats: [:html]

      import Plug.Conn
      use Gettext, backend: AcsWeb.Gettext

      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: AcsWeb.Endpoint,
        router: AcsWeb.Router,
        statics: AcsWeb.static_paths()
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView, layout: {AcsWeb.Layouts, :app}

      unquote(html_helpers())
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent

      unquote(html_helpers())
    end
  end

  def html do
    quote do
      use Phoenix.Component

      unquote(verified_routes())
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      import Phoenix.HTML
      import AcsWeb.CoreComponents

      import Phoenix.Controller,
        only: [get_csrf_token: 0, view_module: 1]

      alias Phoenix.LiveView.JS
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
