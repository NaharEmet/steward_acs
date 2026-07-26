defmodule Acs.Accounts.InvitationNotifierTest do
  use ExUnit.Case, async: true

  import Swoosh.TestAssertions

  alias Acs.Accounts.InvitationNotifier

  setup do
    Application.put_env(:steward_acs, :email_delivery_enabled, true)

    on_exit(fn ->
      Application.put_env(:steward_acs, :email_delivery_enabled, false)
    end)

    :ok
  end

  test "deliver_invitation sends when delivery is enabled" do
    assert :ok =
             InvitationNotifier.deliver_invitation(%{
               to: "invitee@example.test",
               url: "https://prod.stewardacs.xyz/invitations/tok",
               organization_name: "Acme",
               role: "member"
             })

    assert_email_sent(
      to: "invitee@example.test",
      subject: "You're invited to join Acme on Steward"
    )
  end

  test "deliver_invitation includes org-move notice when from_organization_name is set" do
    assert :ok =
             InvitationNotifier.deliver_invitation(%{
               to: "invitee@example.test",
               url: "https://prod.stewardacs.xyz/invitations/tok",
               organization_name: "Acme",
               role: "member",
               from_organization_name: "Old Co"
             })

    assert_email_sent(fn email ->
      assert email.to == [{"", "invitee@example.test"}]
      assert email.text_body =~ "currently belongs to Old Co"
      assert email.text_body =~ "move you to Acme"
    end)
  end

  test "deliver_invitation is a no-op when delivery is disabled" do
    Application.put_env(:steward_acs, :email_delivery_enabled, false)

    assert :disabled =
             InvitationNotifier.deliver_invitation(%{
               to: "invitee@example.test",
               url: "https://example.test/invitations/tok"
             })

    refute_email_sent()
  end
end
