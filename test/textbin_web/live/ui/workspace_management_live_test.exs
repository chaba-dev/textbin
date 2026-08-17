defmodule TextbinWeb.UI.WorkspaceManagementLiveTest do
  use TextbinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Textbin.AccountsFixtures

  alias Textbin.Organizations
  alias Textbin.Organizations.{OrganizationMembership, Workspace, WorkspaceMembership}
  alias Textbin.Repo

  setup %{conn: conn} do
    owner = user_fixture()
    owner_scope = user_scope_fixture(owner)

    {:ok, organization} =
      Organizations.create_organization(owner_scope, %{
        name: "Acme Engineering",
        slug: "workspace-management-#{System.unique_integer([:positive])}"
      })

    {:ok, private_workspace} =
      Organizations.create_workspace(owner_scope, organization, %{
        name: "Platform",
        slug: "platform",
        visibility: "private"
      })

    %{
      conn: log_in_user(conn, owner),
      owner_scope: owner_scope,
      organization: organization,
      default_workspace: Enum.find(organization.workspaces, & &1.is_default),
      private_workspace: private_workspace
    }
  end

  test "organization members discover and join open workspaces without seeing private ones",
       context do
    member = add_organization_member(context, user_fixture())

    {:ok, open_workspace} =
      Organizations.create_workspace(context.owner_scope, context.organization, %{
        name: "Community",
        slug: "community",
        visibility: "open"
      })

    conn = log_in_user(build_conn(), member.user)
    {:ok, view, _html} = live(conn, organization_workspaces_path(context.organization))

    assert has_element?(view, "#organization-workspaces-page")
    assert has_element?(view, "#available-workspaces-#{context.default_workspace.id}", "Joined")
    assert has_element?(view, "#join-workspace-#{open_workspace.id}")
    refute has_element?(view, "#available-workspaces-#{context.private_workspace.id}")
    refute has_element?(view, "#new-workspace-link")

    view
    |> element("#join-workspace-#{open_workspace.id}")
    |> render_click()

    assert_redirect(view, workspace_path(context.organization, open_workspace))

    assert Repo.get_by!(WorkspaceMembership,
             workspace_id: open_workspace.id,
             user_id: member.user.id
           )
  end

  test "members leave non-default workspaces while retaining default workspace access", context do
    member = add_organization_member(context, user_fixture())

    {:ok, open_workspace} =
      Organizations.create_workspace(context.owner_scope, context.organization, %{
        name: "Community",
        slug: "community",
        visibility: "open"
      })

    assert {:ok, membership} =
             Organizations.join_workspace(user_scope_fixture(member.user), open_workspace)

    conn = log_in_user(build_conn(), member.user)
    {:ok, view, _html} = live(conn, organization_workspaces_path(context.organization))

    assert has_element?(view, "#leave-workspace-#{open_workspace.id}")
    refute has_element?(view, "#leave-workspace-#{context.default_workspace.id}")

    view
    |> element("#leave-workspace-#{open_workspace.id}")
    |> render_click()

    refute Repo.get(WorkspaceMembership, membership.id)
    assert has_element?(view, "#join-workspace-#{open_workspace.id}")
    assert has_element?(view, "#available-workspaces-#{context.default_workspace.id}", "Joined")
  end

  test "organization managers create private workspaces with validation", context do
    slug = "design-#{System.unique_integer([:positive])}"

    {:ok, index_view, _html} =
      live(context.conn, organization_workspaces_path(context.organization))

    assert has_element?(
             index_view,
             "#new-workspace-link[href='#{organization_new_workspace_path(context.organization)}']"
           )

    assert has_element?(
             index_view,
             "#organization-menu a[href='#{organization_workspaces_path(context.organization)}'][aria-current='page']"
           )

    {:ok, view, _html} = live(context.conn, organization_new_workspace_path(context.organization))

    assert has_element?(view, "#new-workspace-page")
    assert has_element?(view, "#workspace-form")
    assert has_element?(view, "#back-to-workspaces")

    view
    |> form("#workspace-form", %{
      "workspace" => %{"name" => "Design", "slug" => "Not Valid", "visibility" => "private"}
    })
    |> render_change()

    assert has_element?(view, "#workspace-form", "has invalid format")

    view
    |> form("#workspace-form", %{
      "workspace" => %{
        "name" => "Duplicate",
        "slug" => context.private_workspace.slug,
        "visibility" => "open"
      }
    })
    |> render_submit()

    assert has_element?(view, "#workspace-form", "has already been taken")

    view
    |> form("#workspace-form", %{
      "workspace" => %{"name" => "Design", "slug" => slug, "visibility" => "private"}
    })
    |> render_submit()

    workspace = Repo.get_by!(Workspace, organization_id: context.organization.id, slug: slug)
    assert workspace.name == "Design"
    assert workspace.visibility == "private"
    assert workspace.external_sharing_policy == "disabled"
    assert_redirect(view, workspace_path(context.organization, workspace))
  end

  test "ordinary members cannot open or forge workspace creation", context do
    member = add_organization_member(context, user_fixture())
    conn = log_in_user(build_conn(), member.user)

    assert {:error, {:live_redirect, %{to: path}}} =
             live(conn, organization_new_workspace_path(context.organization))

    assert path == organization_workspaces_path(context.organization)

    {:ok, view, _html} = live(conn, organization_workspaces_path(context.organization))

    render_click(view, "create_workspace", %{
      "workspace" => %{"name" => "Forged", "slug" => "forged", "visibility" => "open"}
    })

    refute Repo.get_by(Workspace, organization_id: context.organization.id, slug: "forged")
  end

  test "workspace creation reauthorizes a manager after demotion", context do
    {:ok, view, _html} = live(context.conn, organization_new_workspace_path(context.organization))
    second_owner = user_fixture()
    second_owner_membership = add_organization_member(context, second_owner)

    assert {:ok, _membership} =
             Organizations.change_organization_member_role(
               context.owner_scope,
               second_owner_membership,
               "owner"
             )

    first_owner_membership =
      Repo.get_by!(OrganizationMembership,
        organization_id: context.organization.id,
        user_id: context.owner_scope.user.id
      )

    assert {:ok, _membership} =
             Organizations.change_organization_member_role(
               user_scope_fixture(second_owner),
               first_owner_membership,
               "member"
             )

    view
    |> form("#workspace-form", %{
      "workspace" => %{
        "name" => "Stale manager",
        "slug" => "stale-manager",
        "visibility" => "open"
      }
    })
    |> render_submit()

    refute Repo.get_by(Workspace,
             organization_id: context.organization.id,
             slug: "stale-manager"
           )

    assert has_element?(view, "#flash-error", "Workspace could not be created")
  end

  test "join events cannot disclose or join a private workspace", context do
    member = add_organization_member(context, user_fixture())
    conn = log_in_user(build_conn(), member.user)
    {:ok, view, _html} = live(conn, organization_workspaces_path(context.organization))

    render_click(view, "join_workspace", %{"id" => context.private_workspace.id})

    refute Repo.get_by(WorkspaceMembership,
             workspace_id: context.private_workspace.id,
             user_id: member.user.id
           )

    assert has_element?(view, "#flash-error", "Workspace could not be joined")
  end

  defp add_organization_member(context, user) do
    {:ok, memberships} =
      Organizations.add_organization_member(context.owner_scope, context.organization, user)

    %{memberships.organization | user: user}
  end

  defp organization_workspaces_path(organization), do: "/o/#{organization.slug}/workspaces"

  defp organization_new_workspace_path(organization),
    do: "/o/#{organization.slug}/workspaces/new"

  defp workspace_path(organization, workspace),
    do: "/w/#{organization.slug}/#{workspace.slug}/pastes"
end
