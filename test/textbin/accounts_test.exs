defmodule Textbin.AccountsTest do
  use Textbin.DataCase

  alias Textbin.Accounts
  alias Textbin.Organizations
  alias Textbin.Organizations.{Organization, OrganizationMembership, WorkspaceMembership}
  alias Textbin.Pastes
  alias Textbin.Pastes.Paste

  import Textbin.AccountsFixtures
  alias Textbin.Accounts.{User, UserToken}

  describe "get_user_by_email/1" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email("unknown@example.com")
    end

    test "returns the user if the email exists" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user_by_email(user.email)
    end
  end

  describe "get_user_by_email_and_password/2" do
    test "does not return the user if the email does not exist" do
      refute Accounts.get_user_by_email_and_password("unknown@example.com", "hello world!")
    end

    test "does not return the user if the password is not valid" do
      user = user_fixture() |> set_password()
      refute Accounts.get_user_by_email_and_password(user.email, "invalid")
    end

    test "returns the user if the email and password are valid" do
      %{id: id} = user = user_fixture() |> set_password()

      assert %User{id: ^id} =
               Accounts.get_user_by_email_and_password(user.email, valid_user_password())
    end
  end

  describe "get_user!/1" do
    test "raises if id is invalid" do
      assert_raise Ecto.NoResultsError, fn ->
        Accounts.get_user!(Ecto.UUID.generate())
      end
    end

    test "returns the user with the given id" do
      %{id: id} = user = user_fixture()
      assert %User{id: ^id} = Accounts.get_user!(user.id)
    end
  end

  describe "register_user/1" do
    test "requires email to be set" do
      {:error, changeset} = Accounts.register_user(%{})

      assert %{email: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email when given" do
      {:error, changeset} = Accounts.register_user(%{email: "not valid"})

      assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
    end

    test "validates maximum values for email for security" do
      too_long = String.duplicate("db", 100)
      {:error, changeset} = Accounts.register_user(%{email: too_long})
      assert "should be at most 160 character(s)" in errors_on(changeset).email
    end

    test "validates email uniqueness" do
      %{email: email} = user_fixture()
      {:error, changeset} = Accounts.register_user(%{email: email})
      assert "has already been taken" in errors_on(changeset).email

      # Now try with the uppercased email too, to check that email case is ignored.
      {:error, changeset} = Accounts.register_user(%{email: String.upcase(email)})
      assert "has already been taken" in errors_on(changeset).email
    end

    test "registers users without password" do
      email = unique_user_email()
      {:ok, user} = Accounts.register_user(valid_user_attributes(email: email))
      assert user.email == email
      assert is_nil(user.hashed_password)
      assert is_nil(user.confirmed_at)
      assert is_nil(user.password)

      organization = Organizations.get_personal_organization!(user)
      assert organization.kind == "personal"
      assert [%{user_id: user_id, role: "owner"}] = organization.memberships
      assert user_id == user.id

      assert [%{is_default: true, visibility: "open", memberships: [membership]}] =
               organization.workspaces

      assert membership.user_id == user.id
      assert membership.role == "owner"
    end
  end

  describe "sudo_mode?/2" do
    test "validates the authenticated_at time" do
      now = DateTime.utc_now()

      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.utc_now()})
      assert Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -19, :minute)})
      refute Accounts.sudo_mode?(%User{authenticated_at: DateTime.add(now, -21, :minute)})

      # minute override
      refute Accounts.sudo_mode?(
               %User{authenticated_at: DateTime.add(now, -11, :minute)},
               -10
             )

      # not authenticated
      refute Accounts.sudo_mode?(%User{})
    end
  end

  describe "change_user_email/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_email(%User{})
      assert changeset.required == [:email]
    end
  end

  describe "deliver_user_update_email_instructions/3" do
    setup do
      %{user: user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(user, "current@example.com", url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "change:current@example.com"
    end
  end

  describe "update_user_email/2" do
    setup do
      user = unconfirmed_user_fixture()
      email = unique_user_email()

      token =
        extract_user_token(fn url ->
          Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
        end)

      %{user: user, token: token, email: email}
    end

    test "updates the email with a valid token", %{user: user, token: token, email: email} do
      assert {:ok, %{email: ^email}} = Accounts.update_user_email(user, token)
      changed_user = Repo.get!(User, user.id)
      assert changed_user.email != user.email
      assert changed_user.email == email
      refute Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email with invalid token", %{user: user} do
      assert Accounts.update_user_email(user, "oops") ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if user email changed", %{user: user, token: token} do
      assert Accounts.update_user_email(%{user | email: "current@example.com"}, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end

    test "does not update email if token expired", %{user: user, token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])

      assert Accounts.update_user_email(user, token) ==
               {:error, :transaction_aborted}

      assert Repo.get!(User, user.id).email == user.email
      assert Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "change_user_password/3" do
    test "returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_password(%User{})
      assert changeset.required == [:password]
    end

    test "allows fields to be set" do
      changeset =
        Accounts.change_user_password(
          %User{},
          %{
            "password" => "new valid password"
          },
          hash_password: false
        )

      assert changeset.valid?
      assert get_change(changeset, :password) == "new valid password"
      assert is_nil(get_change(changeset, :hashed_password))
    end
  end

  describe "update_user_password/2" do
    setup do
      %{user: user_fixture()}
    end

    test "validates password", %{user: user} do
      {:error, changeset} =
        Accounts.update_user_password(user, %{
          password: "not valid",
          password_confirmation: "another"
        })

      assert %{
               password: ["should be at least 12 character(s)"],
               password_confirmation: ["does not match password"]
             } = errors_on(changeset)
    end

    test "validates maximum values for password for security", %{user: user} do
      too_long = String.duplicate("db", 100)

      {:error, changeset} =
        Accounts.update_user_password(user, %{password: too_long})

      assert "should be at most 72 character(s)" in errors_on(changeset).password
    end

    test "updates the password", %{user: user} do
      {:ok, {user, expired_tokens}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      assert expired_tokens == []
      assert is_nil(user.password)
      assert Accounts.get_user_by_email_and_password(user.email, "new valid password")
    end

    test "deletes all tokens for the given user", %{user: user} do
      _ = Accounts.generate_user_session_token(user)

      {:ok, {_, _}} =
        Accounts.update_user_password(user, %{
          password: "new valid password"
        })

      refute Repo.get_by(UserToken, user_id: user.id)
    end
  end

  describe "paste defaults" do
    test "change_user_paste_defaults/2 returns a user changeset" do
      assert %Ecto.Changeset{} = changeset = Accounts.change_user_paste_defaults(%User{})
      assert changeset.required == [:default_paste_ttl]
    end

    test "update_user_paste_defaults/2 updates the default paste ttl" do
      user = user_fixture()

      assert {:ok, %User{} = user} =
               Accounts.update_user_paste_defaults(user, %{default_paste_ttl: "12h"})

      assert user.default_paste_ttl == "12h"
      assert Repo.get!(User, user.id).default_paste_ttl == "12h"
    end

    test "update_user_paste_defaults/2 rejects invalid ttl values" do
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.update_user_paste_defaults(user, %{default_paste_ttl: "forever"})

      assert %{default_paste_ttl: ["is invalid"]} = errors_on(changeset)
    end
  end

  describe "guest users" do
    test "create_guest_user/1 creates a guest user with a generated email" do
      assert {:ok, %User{} = user} = Accounts.create_guest_user()

      assert user.kind == "guest"
      assert user.default_paste_ttl == "6h"
      assert user.email =~ ~r/^guest-.+@guest\.textbin\.local$/
      assert User.guest?(user)

      organization = Organizations.get_personal_organization!(user)
      assert organization.personal_owner_id == user.id

      assert [%{is_default: true, memberships: [%{user_id: user_id, role: "owner"}]}] =
               organization.workspaces

      assert user_id == user.id
    end

    test "create_guest_user/1 preserves atom-key overrides" do
      assert {:ok, %User{} = user} =
               Accounts.create_guest_user(%{default_paste_ttl: "12h"})

      assert user.default_paste_ttl == "12h"
    end

    test "get_guest_user/1 returns only guest users" do
      user = user_fixture()
      {:ok, guest_user} = Accounts.create_guest_user()

      assert Accounts.get_guest_user(guest_user.id).id == guest_user.id
      refute Accounts.get_guest_user(user.id)
      refute Accounts.get_guest_user("not-a-uuid")
    end
  end

  describe "generate_user_session_token/1" do
    setup do
      %{user: user_fixture()}
    end

    test "generates a token", %{user: user} do
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.context == "session"
      assert user_token.authenticated_at != nil

      # Creating the same token for another user should fail
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert!(%UserToken{
          token: user_token.token,
          user_id: user_fixture().id,
          context: "session"
        })
      end
    end

    test "duplicates the authenticated_at of given user in new token", %{user: user} do
      user = %{user | authenticated_at: DateTime.add(DateTime.utc_now(:second), -3600)}
      token = Accounts.generate_user_session_token(user)
      assert user_token = Repo.get_by(UserToken, token: token)
      assert user_token.authenticated_at == user.authenticated_at
      assert DateTime.compare(user_token.inserted_at, user.authenticated_at) == :gt
    end
  end

  describe "get_user_by_session_token/1" do
    setup do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      %{user: user, token: token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert {session_user, token_inserted_at} = Accounts.get_user_by_session_token(token)
      assert session_user.id == user.id
      assert session_user.authenticated_at != nil
      assert token_inserted_at != nil
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_session_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      dt = ~N[2020-01-01 00:00:00]
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: dt, authenticated_at: dt])
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "get_user_by_magic_link_token/1" do
    setup do
      user = user_fixture()
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      %{user: user, token: encoded_token}
    end

    test "returns user by token", %{user: user, token: token} do
      assert session_user = Accounts.get_user_by_magic_link_token(token)
      assert session_user.id == user.id
    end

    test "does not return user for invalid token" do
      refute Accounts.get_user_by_magic_link_token("oops")
    end

    test "does not return user for expired token", %{token: token} do
      {1, nil} = Repo.update_all(UserToken, set: [inserted_at: ~N[2020-01-01 00:00:00]])
      refute Accounts.get_user_by_magic_link_token(token)
    end
  end

  describe "login_user_by_magic_link/1" do
    test "confirms user and expires tokens" do
      user = unconfirmed_user_fixture()
      refute user.confirmed_at
      {encoded_token, hashed_token} = generate_user_magic_link_token(user)

      assert {:ok, {user, [%{token: ^hashed_token}]}} =
               Accounts.login_user_by_magic_link(encoded_token)

      assert user.confirmed_at
    end

    test "returns user and (deleted) token for confirmed user" do
      user = user_fixture()
      assert user.confirmed_at
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)
      assert {:ok, {^user, []}} = Accounts.login_user_by_magic_link(encoded_token)
      # one time use only
      assert {:error, :not_found} = Accounts.login_user_by_magic_link(encoded_token)
    end

    test "raises when unconfirmed user has password set" do
      user = unconfirmed_user_fixture()
      {1, nil} = Repo.update_all(User, set: [hashed_password: "hashed"])
      {encoded_token, _hashed_token} = generate_user_magic_link_token(user)

      assert_raise RuntimeError, ~r/magic link log in is not allowed/, fn ->
        Accounts.login_user_by_magic_link(encoded_token)
      end
    end
  end

  describe "delete_user_session_token/1" do
    test "deletes the token" do
      user = user_fixture()
      token = Accounts.generate_user_session_token(user)
      assert Accounts.delete_user_session_token(token) == :ok
      refute Accounts.get_user_by_session_token(token)
    end
  end

  describe "API tokens" do
    test "creates and lists API tokens" do
      user = user_fixture()

      assert {:ok, {token, user_token}} =
               Accounts.create_user_api_token(user, %{"name" => "CLI"})

      assert token =~ "txb_"
      assert user_token.name == "CLI"
      assert user_token.context == "api"
      refute user_token.token == token

      assert [listed_token] = Accounts.list_user_api_tokens(user)
      assert listed_token.id == user_token.id
      assert listed_token.name == "CLI"
    end

    test "authenticates by API token and updates last_used_at" do
      user = user_fixture()
      {:ok, {token, user_token}} = Accounts.create_user_api_token(user, %{"name" => "CLI"})

      assert {%{id: user_id}, authenticated_token} = Accounts.get_user_and_api_token(token)
      assert user_id == user.id
      assert authenticated_token.id == user_token.id
      assert %DateTime{} = authenticated_token.last_used_at

      assert %{id: user_id} = Accounts.get_user_by_api_token(token)
      assert user_id == user.id

      assert %{last_used_at: %DateTime{}} = Repo.get!(UserToken, user_token.id)
    end

    test "does not authenticate invalid API tokens" do
      refute Accounts.get_user_and_api_token("txb_invalid")
      refute Accounts.get_user_and_api_token("invalid")
      refute Accounts.get_user_by_api_token("txb_invalid")
      refute Accounts.get_user_by_api_token("invalid")
    end

    test "deletes API tokens for the given user only" do
      user = user_fixture()
      other_user = user_fixture()
      {:ok, {_token, user_token}} = Accounts.create_user_api_token(user, %{"name" => "CLI"})

      assert Accounts.delete_user_api_token(other_user, user_token.id) == {:error, :not_found}
      assert Repo.get!(UserToken, user_token.id)

      assert Accounts.delete_user_api_token(user, user_token.id) == :ok
      refute Repo.get(UserToken, user_token.id)
    end
  end

  describe "deliver_login_instructions/2" do
    setup do
      %{user: unconfirmed_user_fixture()}
    end

    test "sends token through notification", %{user: user} do
      token =
        extract_user_token(fn url ->
          Accounts.deliver_login_instructions(user, url)
        end)

      {:ok, token} = Base.url_decode64(token, padding: false)
      assert user_token = Repo.get_by(UserToken, token: :crypto.hash(:sha256, token))
      assert user_token.user_id == user.id
      assert user_token.sent_to == user.email
      assert user_token.context == "login"
    end
  end

  describe "delete_user/1" do
    test "requires transfer only when the user is the final team organization owner" do
      owner = user_fixture()
      successor = user_fixture()
      scope = Textbin.Accounts.Scope.for_user(owner)

      {:ok, organization} =
        Organizations.create_organization(scope, %{
          name: "Deletion safety",
          slug: "deletion-safety-#{System.unique_integer([:positive])}"
        })

      assert {:error, :ownership_transfer_required} = Accounts.delete_user(scope)
      assert Repo.get(User, owner.id)

      {:ok, _memberships} = Organizations.add_organization_member(scope, organization, successor)

      successor_workspace_membership =
        Repo.get_by!(WorkspaceMembership,
          workspace_id: hd(organization.workspaces).id,
          user_id: successor.id
        )

      {:ok, _membership} =
        Organizations.change_workspace_member_role(
          scope,
          successor_workspace_membership,
          "owner"
        )

      membership =
        Repo.get_by!(OrganizationMembership,
          organization_id: organization.id,
          user_id: successor.id
        )

      {:ok, _membership} =
        Organizations.change_organization_member_role(scope, membership, "owner")

      {:ok, team_scope} =
        Organizations.resolve_workspace_scope(scope, hd(organization.workspaces))

      {:ok, team_paste} = Pastes.create_paste(team_scope, %{data: "team data remains"})

      assert {:ok, %User{id: deleted_id}} = Accounts.delete_user(scope)
      assert deleted_id == owner.id
      refute Repo.get(User, owner.id)
      assert Repo.get(Organization, organization.id)

      assert %Paste{created_by_user_id: nil, data: "team data remains"} =
               Repo.get(Paste, team_paste.id)
    end

    test "requires transfer when the user is the final owner of a team workspace" do
      owner = user_fixture()
      successor = user_fixture()
      scope = Textbin.Accounts.Scope.for_user(owner)

      {:ok, organization} =
        Organizations.create_organization(scope, %{
          name: "Workspace transfer",
          slug: "workspace-transfer-#{System.unique_integer([:positive])}"
        })

      {:ok, _memberships} = Organizations.add_organization_member(scope, organization, successor)
      default_workspace = hd(organization.workspaces)

      successor_org_membership =
        Repo.get_by!(OrganizationMembership,
          organization_id: organization.id,
          user_id: successor.id
        )

      {:ok, _membership} =
        Organizations.change_organization_member_role(scope, successor_org_membership, "owner")

      successor_workspace_membership =
        Repo.get_by!(WorkspaceMembership,
          workspace_id: default_workspace.id,
          user_id: successor.id
        )

      {:ok, _membership} =
        Organizations.change_workspace_member_role(
          scope,
          successor_workspace_membership,
          "owner"
        )

      owner_org_membership =
        Repo.get_by!(OrganizationMembership,
          organization_id: organization.id,
          user_id: owner.id
        )

      {:ok, _membership} =
        Organizations.change_organization_member_role(scope, owner_org_membership, "admin")

      {:ok, workspace} =
        Organizations.create_workspace(scope, organization, %{
          name: "Untransferred",
          slug: "untransferred",
          visibility: "private"
        })

      assert {:error, :ownership_transfer_required} = Accounts.delete_user(scope)
      assert Repo.get(User, owner.id)

      assert Repo.get_by!(WorkspaceMembership, workspace_id: workspace.id, user_id: owner.id).role ==
               "owner"
    end

    test "deletes the personal organization, paste rows, and external blobs" do
      user = user_fixture()
      scope = Textbin.Accounts.Scope.for_user(user)
      personal_organization = Organizations.get_personal_organization!(user)

      {:ok, paste} = Pastes.create_paste(scope, %{data: String.duplicate("x", 8_193)})

      {:ok, workspace} =
        Organizations.create_workspace(scope, personal_organization, %{
          name: "Personal project",
          slug: "personal-project",
          visibility: "private"
        })

      {:ok, workspace_scope} = Organizations.resolve_workspace_scope(scope, workspace)

      {:ok, workspace_paste} =
        Pastes.create_paste(workspace_scope, %{data: String.duplicate("y", 8_193)})

      assert is_binary(paste.storage_key)
      assert is_binary(workspace_paste.storage_key)

      assert {:ok, %User{id: deleted_id}} = Accounts.delete_user(scope)
      assert deleted_id == user.id
      refute Repo.get(User, user.id)
      refute Repo.get(Organization, personal_organization.id)
      refute Repo.get(Paste, paste.id)
      refute Repo.get(Paste, workspace_paste.id)
      assert Textbin.Storage.get(paste.storage_key) == {:error, :enoent}
      assert Textbin.Storage.get(workspace_paste.storage_key) == {:error, :enoent}
    end
  end

  describe "inspect/2 for the User module" do
    test "does not include password" do
      refute inspect(%User{password: "123456"}) =~ "password: \"123456\""
    end
  end
end
