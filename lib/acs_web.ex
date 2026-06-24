defmodule AcsWeb do
  @moduledoc """
  The entrypoint for defining your web interface, such
  as controllers, components, channels, and liveviews.
  """

  def router do
    quote do
      use Phoenix.Router, helpers: false
      import Phoenix.Component
      import Phoenix.LiveView.Router
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
      use Phoenix.VerifiedRoutes,
        endpoint: AcsWeb.Endpoint,
        router: AcsWeb.Router

      import Phoenix.Controller,
        only: [get_csrf_token: 0]

      import AcsWeb.CoreComponents
      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      # HTML escaping functionality
      import Phoenix.HTML
      # Core UI components
      import AcsWeb.CoreComponents
      # CSRF token for meta tags (delegated to Plug.CSRFProtection)
      import Phoenix.Controller, only: [get_csrf_token: 0]
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
