defmodule Textbin.AdministrationTest do
  use Textbin.DataCase, async: false

  alias Textbin.Accounts
  alias Textbin.Accounts.{Scope, User, UserToken}
  alias Textbin.Administration
  alias Textbin.Administration.PlatformAuditEvent
  alias Textbin.Organizations
  alias Textbin.Release

  import Textbin.AccountsFixtures

  describe "bootstrap_platform_admin/1" do
    test "grants a confirmed user idempotently and audits every invocation" do
      user = user_fixture()

      assert {:ok, :granted} =
               Release.grant_platform_admin(String.upcase(user.email))

      assert Repo.get!(User, user.id).platform_role == "admin"

      assert {:ok, :already_present} =
               Administration.bootstrap_platform_admin(user.email)

      events =
        Repo.all(
          from event in PlatformAuditEvent,
            where: event.target_id == ^user.id,
            order_by: [asc: event.inserted_at]
        )

      assert Enum.map(events, & &1.actor_kind) == ["bootstrap", "bootstrap"]
      assert Enum.map(events, & &1.actor_label) == ["release_rpc", "release_rpc"]
      assert Enum.map(events, & &1.metadata["result"]) == ["granted", "already_present"]
    end

    test "rejects missing, unconfirmed, guest, and suspended users" do
      unconfirmed = unconfirmed_user_fixture()
      guest = guest_user()
      suspended = user_fixture()

      Repo.update_all(from(user in User, where: user.id == ^suspended.id),
        set: [suspended_at: DateTime.utc_now(:second)]
      )

      assert {:error, :not_found} =
               Administration.bootstrap_platform_admin("missing@example.com")

      assert {:error, :unconfirmed} =
               Administration.bootstrap_platform_admin(unconfirmed.email)

      assert {:error, :ineligible} = Administration.bootstrap_platform_admin(guest.email)
      assert {:error, :suspended} = Administration.bootstrap_platform_admin(suspended.email)
    end
  end

  describe "platform authorization" do
    test "reloads authority instead of trusting the scope user" do
      admin = admin_fixture()
      scope = admin_scope(admin)

      assert {:ok, %User{id: id}} = Administration.authorize_platform_admin(scope)
      assert id == admin.id

      Repo.update_all(from(user in User, where: user.id == ^admin.id), set: [platform_role: nil])

      assert {:error, :forbidden} = Administration.authorize_platform_admin(scope)
    end

    test "organization owners and admins have no platform authority" do
      owner = user_fixture()
      organization_admin = user_fixture()
      target = user_fixture()

      assert {:ok, organization} =
               Organizations.create_organization(Scope.for_user(owner), %{
                 name: "Platform isolation",
                 slug: "platform-isolation-#{System.unique_integer([:positive])}"
               })

      assert {:ok, memberships} =
               Organizations.add_organization_member(
                 Scope.for_user(owner),
                 organization,
                 organization_admin
               )

      assert {:ok, _membership} =
               Organizations.change_organization_member_role(
                 Scope.for_user(owner),
                 memberships.organization,
                 "admin"
               )

      for user <- [owner, organization_admin] do
        scope = Scope.for_user(%{user | authenticated_at: DateTime.utc_now(:second)})
        assert {:error, :forbidden} = Administration.authorize_platform_admin(scope)

        assert {:error, :forbidden} =
                 Administration.grant_platform_admin(scope, target, "not authorized")
      end
    end
  end

  describe "platform authority changes" do
    setup do
      admin = admin_fixture()
      %{admin: admin, scope: admin_scope(admin)}
    end

    test "grants and revokes authority with reasons and request IDs", %{scope: scope} do
      target = user_fixture()

      assert {:ok, %User{platform_role: "admin"}} =
               Administration.grant_platform_admin(scope, target, "operations coverage",
                 request_id: "request-123"
               )

      assert {:ok, %User{platform_role: nil}} =
               Administration.revoke_platform_admin(scope, target, "coverage ended")

      [revoked, granted] =
        Repo.all(
          from event in PlatformAuditEvent,
            where: event.action != "platform.admin.bootstrap",
            order_by: [desc: event.inserted_at]
        )

      assert granted.action == "platform.admin.granted"
      assert granted.reason == "operations coverage"
      assert granted.request_id == "request-123"
      assert revoked.action == "platform.admin.revoked"
      assert revoked.reason == "coverage ended"
    end

    test "requires a reason and recent reauthentication", %{admin: admin} do
      target = user_fixture()

      assert {:error, :reason_required} =
               Administration.grant_platform_admin(admin_scope(admin), target, " ")

      stale_scope =
        Scope.for_user(%{
          admin
          | authenticated_at: DateTime.add(DateTime.utc_now(:second), -21, :minute)
        })

      assert {:error, :reauthentication_required} =
               Administration.grant_platform_admin(stale_scope, target, "needed")
    end

    test "rejects ineligible grant targets", %{scope: scope} do
      unconfirmed = unconfirmed_user_fixture()
      guest = guest_user()

      assert {:error, :unconfirmed} =
               Administration.grant_platform_admin(scope, unconfirmed, "needed")

      assert {:error, :ineligible} =
               Administration.grant_platform_admin(scope, guest, "needed")
    end

    test "protects the final active administrator", %{admin: admin, scope: scope} do
      assert {:error, :final_active_admin} =
               Administration.revoke_platform_admin(scope, admin, "leaving")

      assert Repo.get!(User, admin.id).platform_role == "admin"
    end

    test "transfers the final authority atomically", %{admin: admin, scope: scope} do
      replacement = user_fixture()

      assert {:ok, %{revoked: revoked, replacement: promoted}} =
               Administration.transfer_platform_admin(
                 scope,
                 admin,
                 replacement,
                 "rotation"
               )

      assert revoked.platform_role == nil
      assert promoted.platform_role == "admin"
      assert {:error, :forbidden} = Administration.authorize_platform_admin(scope)
      assert {:ok, _user} = Administration.authorize_platform_admin(admin_scope(promoted))
    end
  end

  describe "account suspension" do
    setup do
      admin = admin_fixture()
      %{admin: admin, scope: admin_scope(admin)}
    end

    test "revokes every token and blocks all authentication", %{scope: scope} do
      user = user_fixture() |> set_password()
      session_token = Accounts.generate_user_session_token(user)
      {:ok, {api_token, _record}} = Accounts.create_user_api_token(user, %{"name" => "CLI"})
      {magic_token, _hashed_token} = generate_user_magic_link_token(user)
      Phoenix.PubSub.subscribe(Textbin.PubSub, Accounts.user_session_topic(session_token))

      assert {:ok, {%User{suspended_at: %DateTime{}} = suspended, tokens}} =
               Administration.suspend_user(scope, user, "abuse")

      assert length(tokens) == 3
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
      refute Repo.exists?(from token in UserToken, where: token.user_id == ^user.id)
      refute Accounts.get_user_by_session_token(session_token)
      refute Accounts.get_user_and_api_token(api_token)
      refute Accounts.get_user_by_magic_link_token(magic_token)
      refute Accounts.get_user_by_email_and_password(user.email, valid_user_password())

      assert_raise ArgumentError, fn -> Accounts.generate_user_session_token(user) end
      assert {:error, :suspended} = Accounts.create_user_api_token(user)

      assert {:error, :suspended} =
               Accounts.deliver_login_instructions(user, fn token -> token end)

      assert {:ok, %User{suspended_at: nil}} =
               Administration.restore_user(scope, suspended, "appeal accepted")

      refute Repo.exists?(from token in UserToken, where: token.user_id == ^user.id)
    end

    test "rejects self-suspension and suspending the final active admin", %{
      admin: admin,
      scope: scope
    } do
      assert {:error, :self_suspension} =
               Administration.suspend_user(scope, admin, "self")

      second_admin = admin_fixture()

      assert {:ok, {_suspended, _tokens}} =
               Administration.suspend_user(scope, second_admin, "removed")

      second_scope = admin_scope(second_admin)
      assert {:error, :forbidden} = Administration.authorize_platform_admin(second_scope)
    end
  end

  describe "platform administrator account deletion" do
    test "protects the final active administrator before deleting account data" do
      admin = admin_fixture()

      assert {:error, :final_active_admin} = Accounts.delete_user(admin_scope(admin))
      assert Repo.get!(User, admin.id)
    end

    test "requires reauthentication and audits an allowed deletion" do
      admin = admin_fixture()
      _replacement = admin_fixture()

      stale_scope =
        Scope.for_user(%{
          admin
          | authenticated_at: DateTime.add(DateTime.utc_now(:second), -21, :minute)
        })

      assert {:error, :reauthentication_required} = Accounts.delete_user(stale_scope)
      assert Repo.get!(User, admin.id)

      assert {:ok, %User{id: deleted_id}} = Accounts.delete_user(admin_scope(admin))
      assert deleted_id == admin.id
      refute Repo.get(User, admin.id)

      assert %PlatformAuditEvent{
               actor_kind: "user",
               actor_user_id: actor_id,
               action: "platform.admin.account_deleted",
               target_id: target_id,
               reason: "account_deleted"
             } =
               Repo.one!(
                 from event in PlatformAuditEvent,
                   where: event.action == "platform.admin.account_deleted"
               )

      assert actor_id == admin.id
      assert target_id == admin.id
    end
  end

  test "platform audit events reject updates and deletes" do
    user = admin_fixture()
    event = Repo.one!(from event in PlatformAuditEvent, where: event.target_id == ^user.id)

    assert_raise Postgrex.Error, ~r/platform audit events are append-only/, fn ->
      Repo.transaction(fn -> Repo.delete!(event) end)
    end
  end

  test "registration cannot assign platform authority or suspension" do
    assert {:ok, user} =
             Accounts.register_user(%{
               email: unique_user_email(),
               platform_role: "admin",
               suspended_at: DateTime.utc_now(:second)
             })

    assert user.platform_role == nil
    assert user.suspended_at == nil
  end

  defp admin_fixture do
    user = user_fixture()
    assert {:ok, _result} = Administration.bootstrap_platform_admin(user.email)
    Repo.get!(User, user.id)
  end

  defp admin_scope(user) do
    Scope.for_user(%{user | authenticated_at: DateTime.utc_now(:second)})
  end

  defp guest_user do
    assert {:ok, user} = Accounts.create_guest_user()
    user
  end
end
