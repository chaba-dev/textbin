defmodule TextbinWeb.ApiV1.OrganizationControllerTest do
  use TextbinWeb.ConnCase, async: true

  alias Textbin.Accounts
  alias Textbin.Organizations
  alias Textbin.Organizations.AuditEvent
  alias Textbin.Repo

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

  test "organization owners recover private workspace ownership and read the audit event",
       context do
    member = user_fixture()

    {:ok, _memberships} =
      Organizations.add_organization_member(context.scope, context.organization, member)

    {:ok, workspace} =
      Organizations.create_workspace(context.scope, context.organization, %{
        name: "Recovery API",
        slug: "recovery-api",
        visibility: "private"
      })

    {:ok, member_membership} =
      Organizations.add_workspace_member(context.scope, workspace, member, "owner")

    assert member_membership.role == "owner"
    assert {:ok, _membership} = Organizations.leave_workspace(context.scope, workspace)

    recovery_conn =
      post(context.conn, ~p"/api/v1/workspaces/#{workspace.id}/recovery")

    assert %{"workspace_id" => workspace_id, "role" => "owner"} =
             json_response(recovery_conn, 201)["data"]

    assert workspace_id == workspace.id

    audit_conn =
      get(context.conn, ~p"/api/v1/organizations/#{context.organization.id}/audit-events")

    assert Enum.any?(json_response(audit_conn, 200)["data"], fn event ->
             event["action"] == "workspace.recovery_access_granted" and
               event["actor_user_id"] == context.user.id and
               event["target_id"] == workspace.id
           end)
  end

  test "audit events are cursor paginated with a bounded page size", context do
    for index <- 1..4 do
      {:ok, _workspace} =
        Organizations.create_workspace(context.scope, context.organization, %{
          name: "Audit page #{index}",
          slug: "audit-page-#{index}",
          visibility: "private"
        })
    end

    first_conn =
      get(
        context.conn,
        ~p"/api/v1/organizations/#{context.organization.id}/audit-events?limit=2"
      )

    assert %{"data" => first_events, "next_cursor" => cursor} = json_response(first_conn, 200)
    assert length(first_events) == 2
    assert is_binary(cursor)

    second_conn =
      get(
        context.conn,
        ~p"/api/v1/organizations/#{context.organization.id}/audit-events?limit=2&cursor=#{cursor}"
      )

    assert %{"data" => second_events} = json_response(second_conn, 200)
    assert length(second_events) == 2

    assert MapSet.disjoint?(
             MapSet.new(first_events, & &1["id"]),
             MapSet.new(second_events, & &1["id"])
           )

    now = DateTime.utc_now()

    inserted_events =
      for index <- 1..105 do
        %{
          id: Ecto.UUID.generate(),
          organization_id: context.organization.id,
          actor_user_id: context.user.id,
          action: "test.event.#{index}",
          target_type: "workspace",
          target_id: Ecto.UUID.generate(),
          metadata: %{},
          inserted_at: now
        }
      end

    Repo.insert_all(AuditEvent, inserted_events)

    bounded_conn =
      get(
        context.conn,
        ~p"/api/v1/organizations/#{context.organization.id}/audit-events?limit=1000"
      )

    assert %{"data" => bounded_events, "next_cursor" => bounded_cursor} =
             json_response(bounded_conn, 200)

    assert length(bounded_events) == 100
    assert is_binary(bounded_cursor)

    boundary_conn =
      get(
        context.conn,
        ~p"/api/v1/organizations/#{context.organization.id}/audit-events?limit=100&cursor=#{bounded_cursor}"
      )

    assert %{"data" => boundary_events} = json_response(boundary_conn, 200)
    assert length(boundary_events) >= 5

    assert MapSet.disjoint?(
             MapSet.new(bounded_events, & &1["id"]),
             MapSet.new(boundary_events, & &1["id"])
           )

    paged_test_event_ids =
      (bounded_events ++ boundary_events)
      |> Enum.filter(&String.starts_with?(&1["action"], "test.event."))
      |> Enum.map(& &1["id"])

    assert paged_test_event_ids ==
             inserted_events |> Enum.map(& &1.id) |> Enum.sort(:desc)
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
