defmodule TextbinWeb.ApiV1.OrganizationControllerTest do
  use TextbinWeb.ConnCase, async: true

  alias Textbin.Accounts
  alias Textbin.Organizations

  import Textbin.AccountsFixtures

  setup do
    user = user_fixture()
    scope = user_scope_fixture(user)

    {:ok, organization} =
      Organizations.create_organization(scope, %{
        name: "API organization",
        slug: "api-organization-#{System.unique_integer([:positive])}"
      })

    %{conn: api_conn(user), scope: scope, organization: organization, user: user}
  end

  test "lists only organizations the API user belongs to", context do
    other_scope = user_scope_fixture()
    other_organization = Organizations.get_personal_organization!(other_scope.user)

    conn = get(context.conn, ~p"/api/v1/organizations")

    assert conn.private.phoenix_controller == TextbinWeb.ApiV1.OrganizationController
    assert conn.private.phoenix_view["json"] == TextbinWeb.ApiV1.OrganizationJSON

    organization_ids = MapSet.new(json_response(conn, 200)["data"], & &1["id"])
    personal = Organizations.get_personal_organization!(context.user)

    assert organization_ids == MapSet.new([personal.id, context.organization.id])
    refute other_organization.id in organization_ids
  end

  test "lists joined and discoverable open workspaces without exposing private workspaces",
       context do
    member = user_fixture()

    {:ok, _memberships} =
      Organizations.add_organization_member(context.scope, context.organization, member)

    {:ok, open_workspace} =
      Organizations.create_workspace(context.scope, context.organization, %{
        name: "Discoverable",
        slug: "discoverable",
        visibility: "open"
      })

    {:ok, private_workspace} =
      Organizations.create_workspace(context.scope, context.organization, %{
        name: "Concealed",
        slug: "concealed",
        visibility: "private"
      })

    default_workspace = hd(context.organization.workspaces)

    conn =
      member
      |> api_conn()
      |> get(~p"/api/v1/organizations/#{context.organization.id}/workspaces")

    assert %{"organization" => %{"id" => organization_id}, "data" => workspaces} =
             json_response(conn, 200)

    assert organization_id == context.organization.id
    workspace_ids = MapSet.new(workspaces, & &1["id"])
    assert workspace_ids == MapSet.new([default_workspace.id, open_workspace.id])
    refute private_workspace.id in workspace_ids

    assert Enum.all?(workspaces, fn workspace ->
             workspace["organization_id"] == context.organization.id
           end)
  end

  test "conceals organizations the API user cannot access", context do
    outsider = user_fixture()

    conn =
      outsider
      |> api_conn()
      |> get(~p"/api/v1/organizations/#{context.organization.id}/workspaces")

    assert %{"errors" => %{"detail" => "Organization not found"}} = json_response(conn, 404)
  end

  test "returns not found for an invalid organization id", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/organizations/not-a-uuid/workspaces")

    assert %{"errors" => %{"detail" => "Organization not found"}} = json_response(conn, 404)
  end

  test "requires an API token" do
    conn = get(build_conn(), ~p"/api/v1/organizations")

    assert %{"errors" => %{"detail" => "API token required"}} = json_response(conn, 401)
  end

  defp api_conn(user) do
    {:ok, {token, _user_token}} = Accounts.create_user_api_token(user, %{"name" => "API"})
    put_req_header(build_conn(), "authorization", "Bearer #{token}")
  end
end
