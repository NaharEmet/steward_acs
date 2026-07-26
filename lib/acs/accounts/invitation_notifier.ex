defmodule Acs.Accounts.InvitationNotifier do
  @moduledoc """
  Delivers organization invitation emails when Resend is configured.

  Email is purely optional: local/dev never requires it. Remote production
  enables delivery only when `RESEND_API_KEY` (and a from address) are set.
  """

  import Swoosh.Email

  alias Acs.Mailer

  @doc "True when runtime config enabled Resend delivery."
  def delivery_enabled? do
    Application.get_env(:steward_acs, :email_delivery_enabled, false) == true
  end

  @doc """
  Send an invitation email.

  Returns `:ok`, `{:error, reason}`, or `:disabled` when Resend is not configured.
  """
  def deliver_invitation(attrs) when is_map(attrs) do
    if delivery_enabled?() do
      do_deliver(attrs)
    else
      :disabled
    end
  end

  defp do_deliver(%{to: to, url: url} = attrs) when is_binary(to) and is_binary(url) do
    org_name = Map.get(attrs, :organization_name) || "Steward"
    role = Map.get(attrs, :role) || "member"
    from = Application.fetch_env!(:steward_acs, :resend_from_email)
    move_notice = org_move_notice(Map.get(attrs, :from_organization_name), org_name)

    email =
      new()
      |> to(to)
      |> from(from)
      |> subject("You're invited to join #{org_name} on Steward")
      |> text_body("""
      You've been invited to join #{org_name} as #{role}.
      #{move_notice}
      Open this one-time link to accept. Sign in with this exact email address:

      #{url}

      If you weren't expecting this invitation, you can ignore this message.
      """)

    case Mailer.deliver(email) do
      {:ok, _metadata} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_deliver(_attrs), do: {:error, :invalid_attrs}

  defp org_move_notice(from_name, org_name) when is_binary(from_name) and from_name != "" do
    """

    Important: your account currently belongs to #{from_name}. Accepting this invitation will move you to #{org_name} and remove you from #{from_name}.
    """
  end

  defp org_move_notice(_from_name, _org_name), do: ""
end
