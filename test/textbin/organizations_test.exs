defmodule Textbin.OrganizationsTest do
  use Textbin.DataCase

  alias Textbin.Accounts.User
  alias Textbin.Accounts.Scope
  alias Textbin.Organizations
  alias Textbin.Organizations.OrganizationMembership
  alias Textbin.Organizations.Workspace
  alias Textbin.Organizations.WorkspaceMembership

  import Textbin.AccountsFixtures

  describe "user provisioning compatibility" do
    test "database inserts receive a personal organization and default workspace" do
      user = Repo.insert!(%User{email: unique_user_email()})

      organization = Organizations.get_personal_organization!(user)

      assert organization.kind == "personal"
      assert [%{user_id: user_id, role: "owner"}] = organization.memberships

      assert [%{is_default: true, visibility: "open", memberships: [workspace_membership]}] =
               organization.workspaces

      assert user_id == user.id
      assert workspace_membership.user_id == user.id
      assert workspace_membership.role == "owner"
    end

    test "migration locks user writes before backfill and trigger installation" do
      migration =
        File.read!(
          Path.expand(
            "../../priv/repo/migrations/20260810090000_create_organizations_and_workspaces.exs",
            __DIR__
          )
        )

      {lock_position, _length} =
        :binary.match(migration, "LOCK TABLE users IN SHARE ROW EXCLUSIVE MODE")

      [{backfill_position, _length} | _rest] =
        :binary.matches(migration, "backfill_personal_organizations()")

      [{trigger_position, _length} | _rest] =
        :binary.matches(migration, "create_user_provisioning_trigger()")

      assert lock_position < backfill_position
      assert backfill_position < trigger_position
    end
  end

  describe "create_organization/2" do
    test "creates a team organization with an open default workspace" do
      creator = user_fixture()

      assert {:ok, organization} =
               Organizations.create_organization(Scope.for_user(creator), %{
                 name: "Acme",
                 slug: "acme"
               })

      assert organization.kind == "team"
      assert organization.personal_owner_id == nil

      assert [%OrganizationMembership{user_id: user_id, role: "owner"}] =
               organization.memberships

      assert user_id == creator.id

      assert [%Workspace{} = workspace] = organization.workspaces
      assert workspace.name == "Default"
      assert workspace.slug == "default"
      assert workspace.visibility == "open"
      assert workspace.is_default

      assert [%WorkspaceMembership{user_id: user_id, role: "owner"}] =
               workspace.memberships

      assert user_id == creator.id
    end

    test "rolls back all records when the organization is invalid" do
      creator = user_fixture()

      assert {:error, changeset} =
               Organizations.create_organization(Scope.for_user(creator), %{
                 name: "Acme",
                 slug: "Not Valid"
               })

      assert %{slug: ["has invalid format"]} = errors_on(changeset)
      assert Repo.aggregate(OrganizationMembership, :count) == 1
      assert Repo.aggregate(Workspace, :count) == 1
      assert Repo.aggregate(WorkspaceMembership, :count) == 1
    end

    test "returns an error and rolls back when the creator was deleted" do
      creator = user_fixture()
      Repo.delete!(creator)

      assert {:error, changeset} =
               Organizations.create_organization(Scope.for_user(creator), %{
                 name: "Acme",
                 slug: "acme"
               })

      assert %{user_id: ["does not exist"]} = errors_on(changeset)
      assert Repo.aggregate(OrganizationMembership, :count) == 0
      assert Repo.aggregate(Workspace, :count) == 0
    end
  end

  describe "add_organization_member/3" do
    test "adds explicit organization and default-workspace memberships atomically" do
      creator = user_fixture()
      member = user_fixture()

      {:ok, organization} =
        Organizations.create_organization(Scope.for_user(creator), %{name: "Acme", slug: "acme"})

      [workspace] = organization.workspaces

      assert {:ok, memberships} =
               Organizations.add_organization_member(
                 Scope.for_user(creator),
                 organization,
                 member,
                 "admin"
               )

      assert memberships.organization.organization_id == organization.id
      assert memberships.organization.user_id == member.id
      assert memberships.organization.role == "admin"
      assert memberships.workspace.workspace_id == workspace.id
      assert memberships.workspace.user_id == member.id
      assert memberships.workspace.role == "member"
      assert memberships.workspace.created_by_id == creator.id
    end

    test "rejects duplicate membership without duplicating the workspace membership" do
      creator = user_fixture()
      member = user_fixture()

      {:ok, organization} =
        Organizations.create_organization(Scope.for_user(creator), %{name: "Acme", slug: "acme"})

      [workspace] = organization.workspaces

      scope = Scope.for_user(creator)

      assert {:ok, _memberships} =
               Organizations.add_organization_member(scope, organization, member)

      assert {:error, changeset} =
               Organizations.add_organization_member(scope, organization, member)

      assert %{organization_id: ["has already been taken"]} = errors_on(changeset)

      assert Repo.aggregate(
               from(membership in WorkspaceMembership,
                 where:
                   membership.workspace_id == ^workspace.id and membership.user_id == ^member.id
               ),
               :count
             ) == 1
    end

    test "returns an error and rolls back when the organization was deleted" do
      creator = user_fixture()
      member = user_fixture()

      {:ok, organization} =
        Organizations.create_organization(Scope.for_user(creator), %{name: "Acme", slug: "acme"})

      Repo.delete!(organization)

      assert {:error, :not_found} =
               Organizations.add_organization_member(
                 Scope.for_user(creator),
                 organization,
                 member
               )

      refute Repo.get_by(OrganizationMembership,
               organization_id: organization.id,
               user_id: member.id
             )
    end

    test "rejects an ordinary organization member" do
      creator = user_fixture()
      ordinary_member = user_fixture()
      target = user_fixture()

      {:ok, organization} =
        Organizations.create_organization(Scope.for_user(creator), %{name: "Acme", slug: "acme"})

      assert {:ok, _memberships} =
               Organizations.add_organization_member(
                 Scope.for_user(creator),
                 organization,
                 ordinary_member
               )

      assert {:error, :unauthorized} =
               Organizations.add_organization_member(
                 Scope.for_user(ordinary_member),
                 organization,
                 target
               )

      refute Repo.get_by(OrganizationMembership,
               organization_id: organization.id,
               user_id: target.id
             )
    end

    test "does not reveal an organization to a non-member" do
      creator = user_fixture()
      non_member = user_fixture()
      target = user_fixture()

      {:ok, organization} =
        Organizations.create_organization(Scope.for_user(creator), %{name: "Acme", slug: "acme"})

      assert {:error, :not_found} =
               Organizations.add_organization_member(
                 Scope.for_user(non_member),
                 organization,
                 target
               )

      refute Repo.get_by(OrganizationMembership,
               organization_id: organization.id,
               user_id: target.id
             )
    end

    test "allows an organization admin to add a member" do
      creator = user_fixture()
      admin = user_fixture()
      target = user_fixture()

      {:ok, organization} =
        Organizations.create_organization(Scope.for_user(creator), %{name: "Acme", slug: "acme"})

      assert {:ok, _memberships} =
               Organizations.add_organization_member(
                 Scope.for_user(creator),
                 organization,
                 admin,
                 "admin"
               )

      assert {:ok, memberships} =
               Organizations.add_organization_member(
                 Scope.for_user(admin),
                 organization,
                 target
               )

      assert memberships.organization.user_id == target.id
      assert memberships.workspace.created_by_id == admin.id
    end
  end
end
