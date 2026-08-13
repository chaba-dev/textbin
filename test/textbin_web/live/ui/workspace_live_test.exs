defmodule TextbinWeb.UI.WorkspaceLiveTest do
  use TextbinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Textbin.AccountsFixtures

  alias Textbin.Organizations
  alias Textbin.Organizations.WorkspaceMembership
  alias Textbin.Pastes.Paste
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

  test "workspace owners promote members in the default workspace without removing them",
       context do
    member = add_organization_member(context, user_fixture())
    default_workspace = Enum.find(context.organization.workspaces, & &1.is_default)

    membership =
      Repo.get_by!(WorkspaceMembership,
        workspace_id: default_workspace.id,
        user_id: member.id
      )

    context = %{context | workspace: default_workspace}
    {:ok, view, _html} = live(context.conn, workspace_path(context, "members"))

    assert has_element?(view, "#toggle-workspace-role-#{membership.id}")
    refute has_element?(view, "#remove-workspace-member-#{membership.id}")

    view
    |> element("#toggle-workspace-role-#{membership.id}")
    |> render_click()

    assert Repo.reload!(membership).role == "owner"
  end

  test "workspace owners update non-default workspace visibility", context do
    {:ok, view, _html} = live(context.conn, workspace_path(context, "settings"))
    assert has_element?(view, "#workspace-settings-form")

    view
    |> form("#workspace-settings-form", %{"workspace" => %{"visibility" => "open"}})
    |> render_submit()

    assert Repo.reload!(context.workspace).visibility == "open"
  end

  test "workspace owners tighten external sharing and clamp existing paste audiences", context do
    public_paste =
      Repo.insert!(%Paste{
        data: "public",
        audience: "public",
        workspace_id: context.workspace.id,
        created_by_user_id: context.owner.id
      })

    unlisted_paste =
      Repo.insert!(%Paste{
        data: "unlisted",
        audience: "unlisted",
        workspace_id: context.workspace.id,
        created_by_user_id: context.owner.id
      })

    {:ok, view, _html} = live(context.conn, workspace_path(context, "settings"))

    view
    |> form("#workspace-settings-form", %{
      "workspace" => %{
        "visibility" => "private",
        "external_sharing_policy" => "unlisted"
      }
    })
    |> render_submit()

    assert Repo.reload!(public_paste).audience == "unlisted"
    assert Repo.reload!(unlisted_paste).audience == "unlisted"

    view
    |> form("#workspace-settings-form", %{
      "workspace" => %{
        "visibility" => "private",
        "external_sharing_policy" => "disabled"
      }
    })
    |> render_submit()

    assert Repo.reload!(public_paste).audience == "workspace"
    assert Repo.reload!(unlisted_paste).audience == "workspace"
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

  test "member records are concealed from a revoked workspace scope", context do
    member = add_organization_member(context, user_fixture())

    {:ok, membership} =
      Organizations.add_workspace_member(context.owner_scope, context.workspace, member)

    {:ok, stale_scope} =
      Organizations.resolve_workspace_scope(user_scope_fixture(member), context.workspace)

    Repo.delete!(membership)

    assert Organizations.list_workspace_members(stale_scope) == []

    refute Organizations.get_workspace_member(
             stale_scope,
             context.workspace.memberships |> hd() |> Map.fetch!(:id)
           )
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
