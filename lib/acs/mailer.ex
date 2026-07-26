defmodule Acs.Mailer do
  @moduledoc """
  Swoosh mailer for Steward ACS.

  Uses `Swoosh.Adapters.Local` / `Test` by default. Production remote deploys
  switch to `Swoosh.Adapters.Resend` when `RESEND_API_KEY` is set at runtime.
  """
  use Swoosh.Mailer, otp_app: :steward_acs
end
