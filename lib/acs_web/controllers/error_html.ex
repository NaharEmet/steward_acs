defmodule AcsWeb.ErrorHTML do
  @moduledoc """
  Renders HTML error pages. Without this module Phoenix crashes while
  rendering the original error, which hides the real exception.
  """
  use AcsWeb, :html

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
