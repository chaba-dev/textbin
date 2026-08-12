defmodule Textbin.OrganizationsTest do
  use Textbin.DataCase

  alias Textbin.Accounts.Scope
  alias Textbin.Organizations
  alias Textbin.Organizations.OrganizationMembership
  alias Textbin.Organizations.Workspace
  alias Textbin.Organizations.WorkspaceMembership

  import Textbin.AccountsFixtures

  describe "create_organization/2" do
    test "the transaction-free personal organization helper rejects calls outside a transaction" do
      user = user_fixture()

      assert_raise ArgumentError, ~r/must be called inside a Repo transaction/, fn ->
        Organizations.create_personal_organization_in_transaction(user)
      end
    end

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

    test "conceals missing or malformed creators" do
      attrs = %{name: "Acme", slug: "acme"}

      assert {:error, :not_found} = Organizations.create_organization(%Scope{}, attrs)

      assert {:error, :not_found} =
               Organizations.create_organization(
                 Scope.for_user(%Textbin.Accounts.User{id: "not-a-uuid"}),
                 attrs
               )

      assert {:error, :not_found} =
               Organizations.create_organization(
                 Scope.for_user(%Textbin.Accounts.User{id: nil}),
                 attrs
               )
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

  describe "centralized membership lifecycle" do
    setup do
      owner = user_fixture()
      member = user_fixture()

      {:ok, organization} =
        Organizations.create_organization(Scope.for_user(owner), %{
          name: "Lifecycle",
          slug: "lifecycle-#{System.unique_integer([:positive])}"
        })

      {:ok, memberships} =
        Organizations.add_organization_member(Scope.for_user(owner), organization, member)

      %{owner: owner, member: member, organization: organization, memberships: memberships}
    end

    test "resolves all workspace scope records only for explicit members", context do
      workspace = hd(context.organization.workspaces)

      assert {:ok, scope} =
               Organizations.resolve_workspace_scope(Scope.for_user(context.member), workspace)

      assert scope.user.id == context.member.id
      assert scope.organization.id == context.organization.id
      assert scope.organization_membership.id == context.memberships.organization.id
      assert scope.workspace.id == workspace.id
      assert scope.workspace_membership.id == context.memberships.workspace.id

      outsider = user_fixture()

      assert {:error, :not_found} =
               Organizations.resolve_workspace_scope(Scope.for_user(outsider), workspace)
    end

    test "resolver treats malformed, missing, and incomplete access as not found", context do
      scope = Scope.for_user(context.member)

      assert {:error, :not_found} = Organizations.resolve_workspace_scope(scope, nil)
      assert {:error, :not_found} = Organizations.resolve_workspace_scope(scope, "not-a-uuid")

      assert {:error, :not_found} =
               Organizations.resolve_workspace_scope(scope, Ecto.UUID.generate())

      workspace = hd(context.organization.workspaces)
      Repo.delete!(context.memberships.workspace)

      assert {:error, :not_found} = Organizations.resolve_workspace_scope(scope, workspace)
    end

    test "userless scopes and malformed public struct IDs are not found", context do
      assert {:error, :not_found} =
               Organizations.leave_organization(%Scope{}, context.organization)

      assert {:error, :not_found} =
               Organizations.leave_workspace(%Scope{}, hd(context.organization.workspaces))

      malformed = %{context.organization | id: "bad"}

      assert {:error, :not_found} =
               Organizations.leave_organization(Scope.for_user(context.member), malformed)
    end

    test "stale and cross-parent membership structs are not found", context do
      other_owner = user_fixture()

      {:ok, other} =
        Organizations.create_organization(Scope.for_user(other_owner), %{
          name: "Other",
          slug: "other-#{System.unique_integer([:positive])}"
        })

      stale_org = %{context.memberships.organization | organization_id: other.id}
      stale_workspace = %{context.memberships.workspace | workspace_id: hd(other.workspaces).id}

      assert {:error, :not_found} =
               Organizations.change_organization_member_role(
                 Scope.for_user(other_owner),
                 stale_org,
                 "admin"
               )

      assert {:error, :not_found} =
               Organizations.change_workspace_member_role(
                 Scope.for_user(other_owner),
                 stale_workspace,
                 "owner"
               )
    end

    test "owners promote and demote organization and workspace members", context do
      owner_scope = Scope.for_user(context.owner)

      assert {:ok, organization_membership} =
               Organizations.change_organization_member_role(
                 owner_scope,
                 context.memberships.organization,
                 "admin"
               )

      assert organization_membership.role == "admin"

      assert {:ok, workspace_membership} =
               Organizations.change_workspace_member_role(
                 owner_scope,
                 context.memberships.workspace,
                 "owner"
               )

      assert workspace_membership.role == "owner"
    end

    test "an admin cannot perform a transition involving organization owner", context do
      owner_scope = Scope.for_user(context.owner)

      {:ok, admin} =
        Organizations.change_organization_member_role(
          owner_scope,
          context.memberships.organization,
          "admin"
        )

      owner_membership =
        Repo.get_by!(OrganizationMembership,
          organization_id: context.organization.id,
          user_id: context.owner.id
        )

      assert {:error, :unauthorized} =
               Organizations.change_organization_member_role(
                 Scope.for_user(context.member),
                 owner_membership,
                 "member"
               )

      assert Repo.reload!(admin).role == "admin"
      assert Repo.reload!(owner_membership).role == "owner"
    end

    test "protects final owners and default workspace membership", context do
      owner_scope = Scope.for_user(context.owner)
      workspace = hd(context.organization.workspaces)

      owner_organization_membership =
        Repo.get_by!(OrganizationMembership,
          organization_id: context.organization.id,
          user_id: context.owner.id
        )

      owner_workspace_membership =
        Repo.get_by!(WorkspaceMembership, workspace_id: workspace.id, user_id: context.owner.id)

      assert {:error, :last_organization_owner} =
               Organizations.change_organization_member_role(
                 owner_scope,
                 owner_organization_membership,
                 "admin"
               )

      assert {:error, :last_workspace_owner} =
               Organizations.change_workspace_member_role(
                 owner_scope,
                 owner_workspace_membership,
                 "member"
               )

      assert {:error, :default_workspace_membership_required} =
               Organizations.leave_workspace(Scope.for_user(context.member), workspace)
    end

    test "leaving an organization removes its workspace memberships", context do
      assert {:ok, _membership} =
               Organizations.leave_organization(
                 Scope.for_user(context.member),
                 context.organization
               )

      refute Repo.get(OrganizationMembership, context.memberships.organization.id)
      refute Repo.get(WorkspaceMembership, context.memberships.workspace.id)
    end

    test "workspace owners add, remove, and allow members to leave non-default workspaces",
         context do
      workspace = non_default_workspace_fixture(context.organization, context.owner)
      owner_membership = workspace_membership_fixture(workspace, context.owner, "owner")
      scope = Scope.for_user(context.owner)

      assert {:ok, membership} =
               Organizations.add_workspace_member(scope, workspace, context.member)

      assert membership.role == "member"

      assert {:error, duplicate_changeset} =
               Organizations.add_workspace_member(scope, workspace, context.member)

      assert %{workspace_id: ["has already been taken"]} = errors_on(duplicate_changeset)

      assert {:ok, _membership} = Organizations.remove_workspace_member(scope, membership)
      refute Repo.get(WorkspaceMembership, membership.id)

      assert {:ok, membership} =
               Organizations.add_workspace_member(scope, workspace, context.member)

      assert {:ok, _membership} =
               Organizations.leave_workspace(Scope.for_user(context.member), workspace)

      refute Repo.get(WorkspaceMembership, membership.id)
      assert Repo.get(WorkspaceMembership, owner_membership.id)
    end

    test "workspace management requires an owner and organization membership", context do
      workspace = non_default_workspace_fixture(context.organization, context.owner)
      workspace_membership_fixture(workspace, context.owner, "owner")
      member_membership = workspace_membership_fixture(workspace, context.member, "member")
      target = user_fixture()

      assert {:error, :not_found} =
               Organizations.add_workspace_member(
                 Scope.for_user(context.owner),
                 workspace,
                 target
               )

      assert {:error, :unauthorized} =
               Organizations.add_workspace_member(
                 Scope.for_user(context.member),
                 workspace,
                 context.owner
               )

      assert {:error, :unauthorized} =
               Organizations.remove_workspace_member(
                 Scope.for_user(context.member),
                 member_membership
               )
    end

    test "workspace changes reject an orphaned target membership", context do
      workspace = non_default_workspace_fixture(context.organization, context.owner)
      workspace_membership_fixture(workspace, context.owner, "owner")
      target_membership = workspace_membership_fixture(workspace, context.member, "member")

      Repo.delete!(context.memberships.organization)

      assert {:error, :not_found} =
               Organizations.change_workspace_member_role(
                 Scope.for_user(context.owner),
                 target_membership,
                 "owner"
               )

      assert {:error, :not_found} =
               Organizations.remove_workspace_member(
                 Scope.for_user(context.owner),
                 target_membership
               )

      assert Repo.get(WorkspaceMembership, target_membership.id).role == "member"
    end

    test "organization removal revokes every workspace membership atomically", context do
      open_workspace = non_default_workspace_fixture(context.organization, context.owner)

      private_workspace =
        non_default_workspace_fixture(context.organization, context.owner, "private")

      for workspace <- [open_workspace, private_workspace] do
        workspace_membership_fixture(workspace, context.owner, "owner")
        workspace_membership_fixture(workspace, context.member, "member")
      end

      assert {:ok, _membership} =
               Organizations.remove_organization_member(
                 Scope.for_user(context.owner),
                 context.memberships.organization
               )

      refute Repo.get(OrganizationMembership, context.memberships.organization.id)

      refute Repo.exists?(
               from membership in WorkspaceMembership,
                 join: workspace in Workspace,
                 on: workspace.id == membership.workspace_id,
                 where:
                   workspace.organization_id == ^context.organization.id and
                     membership.user_id == ^context.member.id
             )

      assert_default_memberships_match(context.organization)
    end

    test "organization removal refuses a member who is a final workspace owner", context do
      workspace = non_default_workspace_fixture(context.organization, context.owner)
      target_owner = workspace_membership_fixture(workspace, context.member, "owner")

      assert {:error, :last_workspace_owner} =
               Organizations.remove_organization_member(
                 Scope.for_user(context.owner),
                 context.memberships.organization
               )

      assert Repo.get(OrganizationMembership, context.memberships.organization.id)
      assert Repo.get(WorkspaceMembership, context.memberships.workspace.id)
      assert Repo.get(WorkspaceMembership, target_owner.id)
      assert_default_memberships_match(context.organization)
    end

    test "admins manage ordinary members while ordinary members are denied", context do
      target = user_fixture()
      owner_scope = Scope.for_user(context.owner)

      {:ok, admin_membership} =
        Organizations.change_organization_member_role(
          owner_scope,
          context.memberships.organization,
          "admin"
        )

      {:ok, target_memberships} =
        Organizations.add_organization_member(
          Scope.for_user(context.member),
          context.organization,
          target
        )

      assert {:ok, changed} =
               Organizations.change_organization_member_role(
                 Scope.for_user(context.member),
                 target_memberships.organization,
                 "admin"
               )

      assert changed.role == "admin"

      ordinary = user_fixture()

      assert {:ok, ordinary_memberships} =
               Organizations.add_organization_member(owner_scope, context.organization, ordinary)

      assert {:error, :unauthorized} =
               Organizations.remove_organization_member(
                 Scope.for_user(ordinary),
                 admin_membership
               )

      assert {:ok, _removed} =
               Organizations.remove_organization_member(
                 Scope.for_user(context.member),
                 ordinary_memberships.organization
               )
    end

    test "organization addition rolls back when default membership cannot be synchronized",
         context do
      target = user_fixture()
      default_workspace = hd(context.organization.workspaces)

      workspace_membership_fixture(default_workspace, target, "member")

      assert {:error, %Ecto.Changeset{}} =
               Organizations.add_organization_member(
                 Scope.for_user(context.owner),
                 context.organization,
                 target
               )

      refute Repo.get_by(OrganizationMembership,
               organization_id: context.organization.id,
               user_id: target.id
             )

      Repo.delete_all(
        from membership in WorkspaceMembership,
          where:
            membership.workspace_id == ^default_workspace.id and
              membership.user_id == ^target.id
      )

      Repo.delete!(default_workspace)

      assert {:error, :default_workspace_not_found} =
               Organizations.add_organization_member(
                 Scope.for_user(context.owner),
                 context.organization,
                 target
               )

      refute Repo.get_by(OrganizationMembership,
               organization_id: context.organization.id,
               user_id: target.id
             )
    end
  end

  defp non_default_workspace_fixture(organization, creator, visibility \\ "open") do
    slug = "workspace-#{System.unique_integer([:positive])}"

    %Workspace{
      organization_id: organization.id,
      created_by_id: creator.id,
      is_default: false
    }
    |> Workspace.changeset(%{name: slug, slug: slug, visibility: visibility})
    |> Repo.insert!()
  end

  defp workspace_membership_fixture(workspace, user, role) do
    %WorkspaceMembership{
      workspace_id: workspace.id,
      user_id: user.id,
      created_by_id: user.id,
      role: role
    }
    |> WorkspaceMembership.changeset()
    |> Repo.insert!()
  end

  defp assert_default_memberships_match(organization) do
    default_workspace =
      Repo.get_by!(Workspace, organization_id: organization.id, is_default: true)

    organization_users =
      Repo.all(
        from membership in OrganizationMembership,
          where: membership.organization_id == ^organization.id,
          select: membership.user_id
      )
      |> MapSet.new()

    workspace_users =
      Repo.all(
        from membership in WorkspaceMembership,
          where: membership.workspace_id == ^default_workspace.id,
          select: membership.user_id
      )
      |> MapSet.new()

    assert organization_users == workspace_users
  end
end
