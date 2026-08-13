defmodule TextbinWeb.UI.WorkspaceLiveTest do
  use TextbinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Textbin.AccountsFixtures

  alias Textbin.Organizations
  alias Textbin.Organizations.WorkspaceMembership
  alias Textbin.Repo

  setup %{conn: conn} do
    owner = user_fixture()
    owner_scope = user_scope_fixture(owner)
    slug = "workspace-ui-#{System.unique_integer([:positive])}"

    {:ok, organization} =
      Organizations.create_organization(owner_scope, %{name: "Workspace UI", slug: slug})

    {:ok, workspace} =
      Organizations.create_workspace(owner_scope, organization, %{
        name: "Product",
        slug: "product",
        visibility: "private"
      })

    %{
      conn: log_in_user(conn, owner),
      owner: owner,
      owner_scope: owner_scope,
      organization: organization,
      workspace: workspace
    }
  end

  test "requires authentication for workspace membership and settings pages", context do
    for page <- ["members", "settings"] do
      assert {:error, {:redirect, %{to: path}}} =
               live(build_conn(), workspace_path(context, page))

      assert path == ~p"/users/log-in"
    end
  end

  test "lists only members of the selected workspace and links workspace pages", context do
    member = add_organization_member(context, user_fixture())

    {:ok, membership} =
      Organizations.add_workspace_member(context.owner_scope, context.workspace, member)

    other_user = user_fixture()
    other_workspace = create_workspace(context, "Other", "other")

    {:ok, _membership} =
      Organizations.add_organization_member(context.owner_scope, context.organization, other_user)

    {:ok, _membership} =
      Organizations.add_workspace_member(context.owner_scope, other_workspace, other_user)

    {:ok, view, _html} = live(context.conn, workspace_path(context, "members"))

    assert has_element?(view, "#workspace-members")
    assert has_element?(view, "#members-#{membership.id}", member.email)
    refute has_element?(view, "#workspace-members", other_user.email)

    assert has_element?(
             view,
             "#workspace-page-navigation a[href='#{workspace_path(context, "pastes")}']"
           )

    assert has_element?(
             view,
             "#workspace-page-navigation a[href='#{workspace_path(context, "settings")}']"
           )
  end

  test "workspace owners add, promote, and remove members", context do
    member = add_organization_member(context, user_fixture())
    {:ok, view, _html} = live(context.conn, workspace_path(context, "members"))

    view
    |> form("#workspace-member-form", %{"member" => %{"email" => member.email}})
    |> render_submit()

    membership =
      Repo.get_by!(WorkspaceMembership, workspace_id: context.workspace.id, user_id: member.id)

    assert has_element?(view, "#members-#{membership.id}", member.email)

    view
    |> element("#toggle-workspace-role-#{membership.id}")
    |> render_click()

    assert Repo.reload!(membership).role == "owner"

    view
    |> element("#remove-workspace-member-#{membership.id}")
    |> render_click()

    refute Repo.get(WorkspaceMembership, membership.id)
    refute has_element?(view, "#members-#{membership.id}")
  end

  test "workspace owners update non-default workspace visibility", context do
    {:ok, view, _html} = live(context.conn, workspace_path(context, "settings"))
    assert has_element?(view, "#workspace-settings-form")

    view
    |> form("#workspace-settings-form", %{"workspace" => %{"visibility" => "open"}})
    |> render_submit()

    assert Repo.reload!(context.workspace).visibility == "open"
  end

  test "members can view settings but cannot mutate them", context do
    member = add_organization_member(context, user_fixture())

    {:ok, _membership} =
      Organizations.add_workspace_member(context.owner_scope, context.workspace, member)

    conn = log_in_user(build_conn(), member)
    {:ok, view, _html} = live(conn, workspace_path(context, "settings"))

    assert has_element?(view, "#workspace-settings-readonly", "Private")
    refute has_element?(view, "#workspace-settings-form")
    render_submit(view, "update_settings", %{"workspace" => %{"visibility" => "open"}})
    assert Repo.reload!(context.workspace).visibility == "private"
  end

  test "unjoined and stale workspace URLs are concealed", context do
    outsider = user_fixture()
    outsider_conn = log_in_user(build_conn(), outsider)

    for path <- [workspace_path(context, "members"), workspace_path(context, "settings")] do
      assert_raise Ecto.NoResultsError, fn -> live(outsider_conn, path) end
    end
  end

  defp add_organization_member(context, user) do
    {:ok, _memberships} =
      Organizations.add_organization_member(context.owner_scope, context.organization, user)

    user
  end

  defp create_workspace(context, name, slug) do
    {:ok, workspace} =
      Organizations.create_workspace(context.owner_scope, context.organization, %{
        name: name,
        slug: slug,
        visibility: "private"
      })

    workspace
  end

  defp workspace_path(context, page) do
    "/w/#{context.organization.slug}/#{context.workspace.slug}/#{page}"
  end
end
