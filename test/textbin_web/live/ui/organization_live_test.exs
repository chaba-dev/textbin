defmodule TextbinWeb.UI.OrganizationLiveTest do
  use TextbinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Textbin.AccountsFixtures

  alias Textbin.Organizations
  alias Textbin.Organizations.OrganizationMembership
  alias Textbin.Repo

  setup %{conn: conn} do
    owner = user_fixture()
    owner_scope = user_scope_fixture(owner)
    slug = "organization-ui-#{System.unique_integer([:positive])}"

    {:ok, organization} =
      Organizations.create_organization(owner_scope, %{
        name: "Acme Engineering",
        slug: slug
      })

    {:ok, workspace} =
      Organizations.create_workspace(owner_scope, organization, %{
        name: "Platform",
        slug: "platform",
        visibility: "private"
      })

    default_workspace = Enum.find(organization.workspaces, & &1.is_default)

    %{
      conn: log_in_user(conn, owner),
      owner: owner,
      owner_scope: owner_scope,
      organization: organization,
      default_workspace: default_workspace,
      workspace: workspace
    }
  end

  test "requires authentication", context do
    for path <- [
          "/orgs",
          organization_path(context.organization),
          organization_members_path(context.organization),
          organization_settings_path(context.organization)
        ] do
      assert {:error, {:redirect, %{to: redirected_path}}} = live(build_conn(), path)

      assert redirected_path == ~p"/users/log-in"
    end
  end

  test "lists the organizations available to the user", context do
    {:ok, view, _html} = live(context.conn, "/orgs")
    personal_organization = Organizations.get_personal_organization!(context.owner)

    assert has_element?(view, "#organizations-index")

    assert has_element?(
             view,
             "#organizations-list a[href='#{organization_path(context.organization)}']",
             context.organization.name
           )

    assert has_element?(
             view,
             "#organizations-list a[href='#{organization_path(personal_organization)}']",
             personal_organization.name
           )
  end

  test "sidebar keeps a long workspace list scrollable", context do
    workspaces =
      for index <- 1..15 do
        {:ok, workspace} =
          Organizations.create_workspace(context.owner_scope, context.organization, %{
            name: "Workspace #{index}",
            slug: "workspace-#{index}",
            visibility: "private"
          })

        workspace
      end

    {:ok, view, _html} = live(context.conn, organization_path(context.organization))

    assert has_element?(
             view,
             "#sidebar-navigation-workspaces.overflow-y-auto"
           )

    for workspace <- workspaces do
      assert has_element?(
               view,
               "#sidebar-navigation-workspaces a[href='#{workspace_path(context.organization, workspace)}']"
             )
    end
  end

  test "lists joined workspaces and links to their paste pages", context do
    {:ok, view, _html} = live(context.conn, organization_path(context.organization))

    assert has_element?(view, "#organization-overview")
    assert has_element?(view, "#organization-heading", "Overview")
    assert has_element?(view, "#application-sidebar", context.organization.name)
    assert has_element?(view, "#mobile-sidebar-open")

    assert has_element?(
             view,
             "#sidebar-navigation a[href='#{organization_members_path(context.organization)}']"
           )

    assert has_element?(
             view,
             "#sidebar-navigation a[href='#{organization_settings_path(context.organization)}']"
           )

    for workspace <- [context.default_workspace, context.workspace] do
      assert has_element?(
               view,
               "#workspaces-#{workspace.id}[href='#{workspace_path(context.organization, workspace)}']"
             )
    end
  end

  test "lists only workspaces the organization member has joined", context do
    member = user_fixture()

    assert {:ok, _membership} =
             Organizations.add_organization_member(
               context.owner_scope,
               context.organization,
               member
             )

    conn = log_in_user(build_conn(), member)
    {:ok, view, _html} = live(conn, organization_path(context.organization))

    assert has_element?(view, "#workspaces-#{context.default_workspace.id}")
    refute has_element?(view, "#workspaces-#{context.workspace.id}")
  end

  test "lists organization members", context do
    member = add_organization_member(context, user_fixture())
    {:ok, view, _html} = live(context.conn, organization_members_path(context.organization))

    assert has_element?(view, "#organization-members-page")
    assert has_element?(view, "#organization-members")
    assert has_element?(view, "#members-#{member.id}", member.user.email)
    assert has_element?(view, "#organization-member-role-#{member.id}", "member")

    assert has_element?(
             view,
             "#sidebar-navigation a[href='#{organization_path(context.organization)}']"
           )
  end

  test "organization owners add, promote, and remove members", context do
    user = user_fixture()
    {:ok, view, _html} = live(context.conn, organization_members_path(context.organization))

    view
    |> form("#organization-member-form", %{"member" => %{"email" => user.email}})
    |> render_submit()

    membership =
      Repo.get_by!(OrganizationMembership,
        organization_id: context.organization.id,
        user_id: user.id
      )

    assert has_element?(view, "#members-#{membership.id}", user.email)

    view
    |> element("#change-organization-role-#{membership.id}-admin")
    |> render_click()

    assert Repo.reload!(membership).role == "admin"
    assert has_element?(view, "#organization-member-role-#{membership.id}", "admin")

    view
    |> element("#remove-organization-member-#{membership.id}")
    |> render_click()

    refute Repo.get(OrganizationMembership, membership.id)
    refute has_element?(view, "#members-#{membership.id}")
  end

  test "ordinary organization members get a read-only directory", context do
    membership = add_organization_member(context, user_fixture())
    conn = log_in_user(build_conn(), membership.user)
    {:ok, view, _html} = live(conn, organization_members_path(context.organization))

    assert has_element?(view, "#members-#{membership.id}")
    refute has_element?(view, "#organization-member-form")
    refute has_element?(view, "[id^='change-organization-role-']")
    refute has_element?(view, "[id^='remove-organization-member-']")

    render_click(view, "change_member_role", %{"id" => membership.id, "role" => "admin"})
    assert Repo.reload!(membership).role == "member"
  end

  test "organization admins manage non-owner members without owner controls", context do
    admin_user = user_fixture()
    admin = add_organization_member(context, admin_user)

    {:ok, admin} =
      Organizations.change_organization_member_role(context.owner_scope, admin, "admin")

    target = add_organization_member(context, user_fixture())

    owner_membership =
      Repo.get_by!(OrganizationMembership,
        organization_id: context.organization.id,
        user_id: context.owner.id
      )

    conn = log_in_user(build_conn(), admin_user)
    {:ok, view, _html} = live(conn, organization_members_path(context.organization))

    assert has_element?(view, "#organization-member-form")
    refute has_element?(view, "#change-organization-role-#{owner_membership.id}-member")
    refute has_element?(view, "#remove-organization-member-#{owner_membership.id}")
    refute has_element?(view, "#change-organization-role-#{admin.id}-member")
    assert has_element?(view, "#change-organization-role-#{target.id}-admin")

    view
    |> element("#change-organization-role-#{target.id}-admin")
    |> render_click()

    assert Repo.reload!(target).role == "admin"
  end

  test "organization owners update the display name while the slug stays read-only", context do
    {:ok, view, _html} = live(context.conn, organization_settings_path(context.organization))

    assert has_element?(view, "#organization-settings-page")
    assert has_element?(view, "#organization-settings-form")
    assert has_element?(view, "#organization-slug[disabled]")
    refute has_element?(view, "#organization-settings-form input[name='organization[slug]']")

    view
    |> form("#organization-settings-form", %{"organization" => %{"name" => "Acme Labs"}})
    |> render_submit()

    assert Repo.reload!(context.organization).name == "Acme Labs"
    assert Repo.reload!(context.organization).slug == context.organization.slug
    assert has_element?(view, "#application-sidebar", "Acme Labs")
  end

  test "organization members view read-only settings and cannot forge an update", context do
    membership = add_organization_member(context, user_fixture())
    conn = log_in_user(build_conn(), membership.user)
    {:ok, view, _html} = live(conn, organization_settings_path(context.organization))

    assert has_element?(view, "#organization-settings-readonly", context.organization.name)
    refute has_element?(view, "#organization-settings-form")

    render_click(view, "update_settings", %{"organization" => %{"name" => "Forged"}})

    assert Repo.reload!(context.organization).name == context.organization.name
  end

  test "settings event cannot update an organization from another organization page", context do
    {:ok, view, _html} = live(context.conn, organization_path(context.organization))

    render_click(view, "update_settings", %{"organization" => %{"name" => "Forged"}})

    assert Repo.reload!(context.organization).name == context.organization.name
  end

  test "mounted settings page reauthorizes an owner after demotion", context do
    {:ok, view, _html} = live(context.conn, organization_settings_path(context.organization))
    second_owner = user_fixture()

    {:ok, second_owner_memberships} =
      Organizations.add_organization_member(
        context.owner_scope,
        context.organization,
        second_owner
      )

    {:ok, _second_owner_membership} =
      Organizations.change_organization_member_role(
        context.owner_scope,
        second_owner_memberships.organization,
        "owner"
      )

    first_owner_membership =
      Repo.get_by!(OrganizationMembership,
        organization_id: context.organization.id,
        user_id: context.owner.id
      )

    assert {:ok, _demoted_membership} =
             Organizations.change_organization_member_role(
               user_scope_fixture(second_owner),
               first_owner_membership,
               "admin"
             )

    view
    |> form("#organization-settings-form", %{
      "organization" => %{"name" => "Stale owner edit"}
    })
    |> render_submit()

    assert Repo.reload!(context.organization).name == context.organization.name
  end

  test "conceals organizations the user has not joined", context do
    outsider_conn = build_conn() |> log_in_user(user_fixture())

    for path <- [
          organization_path(context.organization),
          organization_members_path(context.organization),
          organization_settings_path(context.organization)
        ] do
      assert_raise Ecto.NoResultsError, fn -> live(outsider_conn, path) end
    end
  end

  test "workspace pages link back to the organization overview", context do
    {:ok, view, _html} =
      live(context.conn, workspace_settings_path(context.organization, context.workspace))

    assert has_element?(
             view,
             "#sidebar-navigation a[href='#{organization_path(context.organization)}']"
           )
  end

  defp organization_path(organization), do: "/o/#{organization.slug}"
  defp organization_members_path(organization), do: "/o/#{organization.slug}/members"
  defp organization_settings_path(organization), do: "/o/#{organization.slug}/settings"

  defp add_organization_member(context, user) do
    {:ok, memberships} =
      Organizations.add_organization_member(context.owner_scope, context.organization, user)

    %{memberships.organization | user: user}
  end

  defp workspace_path(organization, workspace),
    do: "/w/#{organization.slug}/#{workspace.slug}/pastes"

  defp workspace_settings_path(organization, workspace),
    do: "/w/#{organization.slug}/#{workspace.slug}/settings"
end
