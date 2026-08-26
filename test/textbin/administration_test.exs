defmodule Textbin.AdministrationTest do
  use Textbin.DataCase, async: false

  alias Textbin.Accounts
  alias Textbin.Accounts.{Scope, User, UserToken}
  alias Textbin.Administration
  alias Textbin.Administration.PlatformAuditEvent
  alias Textbin.Organizations
  alias Textbin.Pastes
  alias Textbin.Pastes.Paste
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

    test "queues an authority notification before follow-up authorization" do
      actor = admin_fixture()
      target = admin_fixture()
      target_scope = admin_scope(target)
      parent = self()

      watcher =
        Task.async(fn ->
          assert :ok = Administration.subscribe_to_platform_authority(target_scope)
          send(parent, {:subscribed, self()})
          assert_receive :authorize

          authorization = Administration.authorize_platform_admin(target_scope)
          assert_receive notification
          {authorization, notification}
        end)

      assert_receive {:subscribed, watcher_pid}

      assert {:ok, %User{platform_role: nil}} =
               Administration.revoke_platform_admin(
                 admin_scope(actor),
                 target,
                 "subscription race"
               )

      send(watcher_pid, :authorize)

      assert {{:error, :forbidden}, :platform_authority_changed} = Task.await(watcher)
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

    test "rolls back authority changes when their audit event is invalid", %{scope: scope} do
      target = user_fixture()

      assert {:error, %Ecto.Changeset{}} =
               Administration.grant_platform_admin(scope, target, "operations coverage",
                 request_id: String.duplicate("x", 256)
               )

      assert Repo.get!(User, target.id).platform_role == nil
      refute Repo.exists?(from event in PlatformAuditEvent, where: event.target_id == ^target.id)
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

      assert ["platform.account.suspended", "platform.account.restored"] ==
               Repo.all(
                 from event in PlatformAuditEvent,
                   where: event.target_id == ^user.id,
                   order_by: [asc: event.inserted_at],
                   select: event.action
               )
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

  describe "administration reads" do
    setup do
      admin = admin_fixture()
      %{admin: admin, scope: admin_scope(admin)}
    end

    test "reloads authority for every read and rejects ordinary users", %{
      admin: admin,
      scope: scope
    } do
      ordinary_scope = user_scope_fixture()

      for operation <- [
            &Administration.get_installation_overview/1,
            &Administration.lookup(&1, admin.email),
            &Administration.list_recent_public_pastes/1,
            &Administration.list_largest_pastes/1,
            &Administration.list_platform_audit_events/1
          ] do
        assert {:error, :forbidden} = operation.(ordinary_scope)
      end

      assert {:ok, _overview} = Administration.get_installation_overview(scope)
      Repo.update_all(from(user in User, where: user.id == ^admin.id), set: [platform_role: nil])
      assert {:error, :forbidden} = Administration.get_installation_overview(scope)
    end

    test "returns installation totals and exact lookup summaries", %{scope: scope} do
      target = user_fixture()
      target_scope = user_scope_fixture(target)
      organization = Organizations.get_personal_organization!(target)
      workspace = personal_workspace_fixture(target)
      assert {:ok, _paste} = Pastes.create_paste(target_scope, %{data: "lookup paste"})

      assert {:ok, overview} = Administration.get_installation_overview(scope)
      assert overview.registered_users >= 2
      assert overview.organizations >= 2
      assert overview.workspaces >= 2
      assert overview.active_pastes >= 1

      assert {:ok, %{user: user}} = Administration.lookup(scope, String.upcase(target.email))
      assert user.id == target.id
      assert user.organization_memberships == 1
      assert user.workspace_memberships == 1
      assert user.pastes == 1
      refute Map.has_key?(user, :hashed_password)

      assert {:ok, %{organization: found_organization}} =
               Administration.lookup(scope, organization.slug)

      assert found_organization.id == organization.id
      assert found_organization.members == 1
      assert found_organization.workspaces == 1

      assert {:ok, %{workspace: found_workspace}} =
               Administration.lookup(scope, "#{organization.slug}/#{workspace.slug}")

      assert found_workspace.id == workspace.id
      assert found_workspace.members == 1
      assert found_workspace.pastes == 1
    end

    test "paginates body-free paste metadata and limits discovery to public pastes", %{
      scope: scope
    } do
      owner = user_fixture()
      owner_scope = user_scope_fixture(owner)

      assert {:ok, public} =
               Pastes.create_paste(owner_scope, %{
                 data: "public-body-must-not-load",
                 audience: "public"
               })

      assert {:ok, unlisted} =
               Pastes.create_paste(owner_scope, %{
                 data: String.duplicate("u", 200),
                 audience: "unlisted"
               })

      assert {:ok, workspace_only} =
               Pastes.create_paste(owner_scope, %{
                 data: String.duplicate("w", 300),
                 audience: "workspace"
               })

      assert {:ok, recent_page} =
               Administration.list_recent_public_pastes(scope, limit: 1)

      assert [%{id: public_id} = recent] = recent_page.entries
      assert public_id == public.id
      refute Map.has_key?(recent, :data)
      refute Map.has_key?(recent, :storage_key)

      assert {:ok, largest_page} = Administration.list_largest_pastes(scope, limit: 2)
      assert largest_page.next_page == 2
      assert [%{id: nil}, %{id: nil}] = largest_page.entries

      assert {:ok, second_page} =
               Administration.list_largest_pastes(scope, limit: 2, page: largest_page.next_page)

      assert Enum.any?(second_page.entries, &(&1.id == public.id))
      refute Enum.any?(recent_page.entries, &(&1.id in [unlisted.id, workspace_only.id]))
    end

    test "paginates platform audit events", %{scope: scope} do
      _second_admin = admin_fixture()

      assert {:ok, first_page} =
               Administration.list_platform_audit_events(scope, limit: 1)

      assert length(first_page.entries) == 1
      assert first_page.next_cursor

      assert {:ok, second_page} =
               Administration.list_platform_audit_events(scope,
                 limit: 1,
                 cursor: first_page.next_cursor
               )

      assert length(second_page.entries) == 1
      assert first_page.entries != second_page.entries
    end

    test "handles legacy inline pastes without size metadata", %{scope: scope} do
      owner = user_fixture()
      owner_scope = user_scope_fixture(owner)
      workspace = personal_workspace_fixture(owner)

      assert {:ok, modern} =
               Pastes.create_paste(owner_scope, %{data: "modern", audience: "public"})

      legacy_data = "legacy inline content"

      legacy =
        Repo.insert!(%Paste{
          data: legacy_data,
          size_bytes: nil,
          audience: "public",
          workspace_id: workspace.id,
          created_by_user_id: owner.id
        })

      assert {:ok, overview} = Administration.get_installation_overview(scope)
      assert overview.active_paste_bytes >= modern.size_bytes + byte_size(legacy_data)

      assert {:ok, page} = Administration.list_largest_pastes(scope, limit: 100)
      modern_index = Enum.find_index(page.entries, &(&1.id == modern.id))
      legacy_index = Enum.find_index(page.entries, &(&1.id == legacy.id))

      assert modern_index < legacy_index
      assert Enum.at(page.entries, legacy_index).size_bytes == byte_size(legacy_data)
    end

    test "notifies a mounted administrator after revocation", %{admin: admin, scope: scope} do
      actor = admin_fixture()
      :ok = Administration.subscribe_to_platform_authority(scope)

      assert {:ok, %User{platform_role: nil}} =
               Administration.revoke_platform_admin(
                 admin_scope(actor),
                 admin,
                 "rotation complete"
               )

      assert_receive :platform_authority_changed
    end
  end

  test "platform audit events reject updates and deletes" do
    user = admin_fixture()
    event = Repo.one!(from event in PlatformAuditEvent, where: event.target_id == ^user.id)

    assert_raise Postgrex.Error, ~r/platform audit events are append-only/, fn ->
      Repo.transaction(fn ->
        event
        |> Ecto.Changeset.change(reason: "rewritten")
        |> Repo.update!()
      end)
    end

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
