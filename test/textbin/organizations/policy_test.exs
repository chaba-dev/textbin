defmodule Textbin.Organizations.PolicyTest do
  use ExUnit.Case, async: true

  alias Textbin.Organizations.{OrganizationMembership, Policy, Workspace, WorkspaceMembership}

  test "organization admins manage ordinary roles but not owner transitions" do
    admin = %OrganizationMembership{role: Policy.organization_admin_role()}

    assert :ok = Policy.authorize_organization_change(admin, "member", "admin")

    assert {:error, :unauthorized} =
             Policy.authorize_organization_change(admin, "member", "owner")
  end

  test "organization owners manage owner transitions and members manage nothing" do
    owner = %OrganizationMembership{role: Policy.organization_owner_role()}
    member = %OrganizationMembership{role: Policy.organization_member_role()}

    assert :ok = Policy.authorize_organization_change(owner, "owner", "member")
    assert :ok = Policy.authorize_organization_change(owner, "member", "owner")

    assert {:error, :unauthorized} =
             Policy.authorize_organization_change(member, "member", "admin")
  end

  test "only workspace owners manage workspace membership" do
    assert :ok =
             Policy.authorize_workspace_change(%WorkspaceMembership{
               role: Policy.workspace_owner_role()
             })

    assert {:error, :unauthorized} =
             Policy.authorize_workspace_change(%WorkspaceMembership{
               role: Policy.workspace_member_role()
             })
  end

  test "organization owners and admins create workspaces" do
    for role <- [Policy.organization_owner_role(), Policy.organization_admin_role()] do
      assert :ok = Policy.authorize_workspace_creation(%OrganizationMembership{role: role})
    end

    assert {:error, :unauthorized} =
             Policy.authorize_workspace_creation(%OrganizationMembership{
               role: Policy.organization_member_role()
             })
  end

  test "only non-default open workspaces can be joined" do
    assert :ok =
             Policy.authorize_workspace_join(%Workspace{visibility: "open", is_default: false})

    assert {:error, :not_found} =
             Policy.authorize_workspace_join(%Workspace{visibility: "private", is_default: false})

    assert {:error, :not_found} =
             Policy.authorize_workspace_join(%Workspace{visibility: "open", is_default: true})
  end
end
