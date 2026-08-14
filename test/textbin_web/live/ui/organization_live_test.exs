defmodule TextbinWeb.UI.OrganizationLiveTest do
  use TextbinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Textbin.AccountsFixtures

  alias Textbin.Organizations

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
    assert {:error, {:redirect, %{to: path}}} =
             live(build_conn(), organization_path(context.organization))

    assert path == ~p"/users/log-in"
  end

  test "lists joined workspaces and links to their paste pages", context do
    {:ok, view, _html} = live(context.conn, organization_path(context.organization))

    assert has_element?(view, "#organization-overview")
    assert has_element?(view, "#organization-heading", context.organization.name)

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

  test "conceals organizations the user has not joined", context do
    outsider_conn = build_conn() |> log_in_user(user_fixture())

    assert_raise Ecto.NoResultsError, fn ->
      live(outsider_conn, organization_path(context.organization))
    end
  end

  test "workspace pages link back to the organization overview", context do
    {:ok, view, _html} =
      live(context.conn, workspace_settings_path(context.organization, context.workspace))

    assert has_element?(
             view,
             "#organization-overview-link[href='#{organization_path(context.organization)}']"
           )
  end

  defp organization_path(organization), do: "/o/#{organization.slug}"

  defp workspace_path(organization, workspace),
    do: "/w/#{organization.slug}/#{workspace.slug}/pastes"

  defp workspace_settings_path(organization, workspace),
    do: "/w/#{organization.slug}/#{workspace.slug}/settings"
end
