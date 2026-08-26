defmodule Textbin.Accounts.UserNotifierTest do
  use ExUnit.Case, async: false

  alias Textbin.Accounts.{User, UserNotifier}

  import Swoosh.TestAssertions

  setup do
    previous = Application.get_env(:textbin, :mail_from)

    on_exit(fn ->
      if previous do
        Application.put_env(:textbin, :mail_from, previous)
      else
        Application.delete_env(:textbin, :mail_from)
      end
    end)
  end

  test "uses the configured production sender" do
    Application.put_env(:textbin, :mail_from,
      name: "Example Textbin",
      address: "textbin@example.com"
    )

    user = %User{email: "recipient@example.com", confirmed_at: DateTime.utc_now()}

    assert {:ok, _email} =
             UserNotifier.deliver_login_instructions(user, "https://example.com/login")

    assert_email_sent(from: {"Example Textbin", "textbin@example.com"})
  end
end
