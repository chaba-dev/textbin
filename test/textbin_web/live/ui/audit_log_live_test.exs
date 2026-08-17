defmodule TextbinWeb.UI.AuditLogLiveTest do
  use TextbinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Textbin.AccountsFixtures

  alias Textbin.Organizations
  alias Textbin.Organizations.OrganizationMembership
  alias Textbin.Repo

  setup %{conn: conn} do
    owner = user_fixture()
    member = user_fixture()
    owner_scope = user_scope_fixture(owner)

    {:ok, organization} =
      Organizations.create_organization(owner_scope, %{
        name: "Audit Team",
        slug: "audit-team-#{System.unique_integer([:positive])}"
      })

    {:ok, memberships} =
      Organizations.add_organization_member(owner_scope, organization, member)

    {:ok, workspace} =
      Organizations.create_workspace(owner_scope, organization, %{
        name: "Security",
        slug: "security",
        visibility: "private"
      })

    %{
      conn: log_in_user(conn, owner),
      owner: owner,
      member: member,
      member_membership: memberships.organization,
      owner_scope: owner_scope,
      organization: organization,
      workspace: workspace
    }
  end

  test "requires authentication", context do
    assert {:error, {:redirect, %{to: path}}} =
             live(build_conn(), audit_log_path(context.organization))

    assert path == ~p"/users/log-in"
  end

  test "owners review human-readable activity with actor and target context", context do
    {:ok, view, _html} = live(context.conn, audit_log_path(context.organization))

    assert has_element?(view, "#organization-audit-log-page")
    assert has_element?(view, "#audit-events")
    assert has_element?(view, "#audit-events article", "Workspace created")
    assert has_element?(view, "#audit-events article", "Created a private workspace.")
    assert has_element?(view, "#audit-events article .break-all", context.owner.email)

    assert has_element?(
             view,
             "#organization-menu a[href='#{audit_log_path(context.organization)}'][aria-current='page']",
             "Audit log"
           )

    assert has_element?(
             view,
             "#mobile-more-navigation a[href='#{audit_log_path(context.organization)}'][aria-current='page']",
             "Audit log"
           )

    assert has_element?(view, "#mobile-navigation-more.bg-primary\\/10")
  end

  test "admins cannot access or see owner-only audit navigation", context do
    assert {:ok, _membership} =
             Organizations.change_organization_member_role(
               context.owner_scope,
               context.member_membership,
               "admin"
             )

    conn = log_in_user(build_conn(), context.member)
    {:ok, overview, _html} = live(conn, organization_path(context.organization))

    refute has_element?(
             overview,
             "#organization-menu a[href='#{audit_log_path(context.organization)}']"
           )

    refute has_element?(
             overview,
             "#mobile-more-navigation a[href='#{audit_log_path(context.organization)}']"
           )

    assert {:error, {:live_redirect, %{to: path}}} =
             live(conn, audit_log_path(context.organization))

    assert path == organization_path(context.organization)
  end

  test "loads older activity using the server-issued cursor", context do
    for index <- 1..30 do
      {:ok, _workspace} =
        Organizations.create_workspace(context.owner_scope, context.organization, %{
          name: "Audit workspace #{index}",
          slug: "audit-workspace-#{index}",
          visibility: "open"
        })
    end

    assert {:ok, all_events} =
             Organizations.list_audit_events(context.owner_scope, context.organization)

    {:ok, view, _html} = live(context.conn, audit_log_path(context.organization))

    assert element_count(view, "#audit-events article") == 25
    assert has_element?(view, "#audit-events article", "Created an open workspace.")
    assert has_element?(view, "#load-more-audit-events")

    view
    |> element("#load-more-audit-events")
    |> render_click()

    assert element_count(view, "#audit-events article") == length(all_events)
    refute has_element?(view, "#load-more-audit-events")
  end

  test "loading another page reauthorizes an owner after demotion", context do
    for index <- 1..25 do
      {:ok, _workspace} =
        Organizations.create_workspace(context.owner_scope, context.organization, %{
          name: "Authorization event #{index}",
          slug: "authorization-event-#{index}",
          visibility: "open"
        })
    end

    assert {:ok, _membership} =
             Organizations.change_organization_member_role(
               context.owner_scope,
               context.member_membership,
               "owner"
             )

    {:ok, view, _html} = live(context.conn, audit_log_path(context.organization))
    assert has_element?(view, "#load-more-audit-events")

    first_owner_membership =
      Repo.get_by!(OrganizationMembership,
        organization_id: context.organization.id,
        user_id: context.owner.id
      )

    assert {:ok, _membership} =
             Organizations.change_organization_member_role(
               user_scope_fixture(context.member),
               first_owner_membership,
               "member"
             )

    view
    |> element("#load-more-audit-events")
    |> render_click()

    assert_redirect(view, organization_path(context.organization))
  end

  test "conceals audit logs for organizations the user has not joined", context do
    outsider_conn = build_conn() |> log_in_user(user_fixture())

    assert_raise Ecto.NoResultsError, fn ->
      live(outsider_conn, audit_log_path(context.organization))
    end
  end

  defp element_count(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.to_tree()
    |> length()
  end

  defp audit_log_path(organization), do: "/o/#{organization.slug}/audit-log"
  defp organization_path(organization), do: "/o/#{organization.slug}"
end
