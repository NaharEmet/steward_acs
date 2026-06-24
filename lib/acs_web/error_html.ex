defmodule AcsWeb.ErrorHTML do
  use Phoenix.Endpoint, otp_app: :steward_acs

  def render(template, _assigns) do
    "Error: #{template}"
  end
end
