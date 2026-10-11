defmodule TextbinWeb.ApiContractTest do
  @moduledoc """
  Keeps `TextbinWeb.ApiSpec` and the server in step: every API action
  declares its operation, the exported `priv/openapi.json` is current, and
  each operation's real responses match their documented schemas.
  """

  use TextbinWeb.ConnCase, async: false

  import TextbinWeb.ApiContract
  import Textbin.AccountsFixtures

  alias OpenApiSpex.Reference
  alias Textbin.Accounts
  alias Textbin.Organizations
  alias Textbin.Pastes
  alias TextbinWeb.ApiSpec

  @exported_spec Path.expand("../../priv/openapi.json", __DIR__)

  describe "the document" do
    test "every API route's action declares its operation" do
      # The document is built from the router, so an action without an
      # `operation` would silently drop out of it instead of failing.
      for route <- Phoenix.Router.routes(TextbinWeb.Router),
          String.starts_with?(route.path, "/api/") or route.path == "/pastes/:id/raw" do
        assert function_exported?(route.plug, :open_api_operation, 1) and
                 match?(%OpenApiSpex.Operation{}, route.plug.open_api_operation(route.plug_opts)),
               "#{inspect(route.plug)}.#{route.plug_opts} (#{route.verb} #{route.path}) has no `operation` spec"
      end
    end

    test "gives each operation a unique id and resolves every schema reference" do
      operation_ids =
        for {_method, _path, operation} <- ApiSpec.operations(), do: operation.operationId

      assert Enum.uniq(operation_ids) == operation_ids

      spec = ApiSpec.spec()
      known = Map.keys(spec.components.schemas)

      for ref <- references(spec) do
        assert "#/components/schemas/" <> title = ref
        assert title in known, "#{ref} does not resolve"
      end
    end

    test "priv/openapi.json is the exported spec" do
      current =
        ApiSpec.spec() |> OpenApiSpex.OpenApi.to_map() |> Jason.encode!() |> Jason.decode!()

      assert File.exists?(@exported_spec), "run `mix openapi.export` to create priv/openapi.json"

      assert Jason.decode!(File.read!(@exported_spec)) == current,
             "priv/openapi.json is out of date; run `mix openapi.export`"
    end
  end

  describe "authentication" do
    setup :api_user

    test "createApiToken" do
      user = user_fixture()

      build_conn()
      |> post(~p"/api/v1/auth/tokens", %{email: user.email, password: valid_user_password()})
      |> assert_api_response("createApiToken")

      build_conn()
      |> post(~p"/api/v1/auth/tokens", %{email: user.email, password: "wrong password"})
      |> assert_api_response("createApiToken")

      build_conn()
      |> post(~p"/api/v1/auth/tokens", %{})
      |> assert_api_response("createApiToken")
    end

    test "getIdentity and revokeCurrentToken", %{conn: conn} do
      conn |> get(~p"/api/v1/me") |> assert_api_response("getIdentity")
      build_conn() |> get(~p"/api/v1/me") |> assert_api_response("getIdentity")
      conn |> delete(~p"/api/v1/me/token") |> assert_api_response("revokeCurrentToken")
    end
  end

  describe "organizations" do
    setup [:api_user, :team_organization]

    test "rejects quoted booleans, missing fields and undocumented fields", context do
      response =
        get(context.conn, ~p"/api/v1/organizations/#{context.organization.id}/workspaces")

      body = json_response(response, 200)
      [workspace | rest] = body["data"]

      for invalid <- [
            Map.put(workspace, "is_default", "false"),
            Map.delete(workspace, "is_default"),
            Map.put(workspace, "surprise", true)
          ] do
        malformed = %{response | resp_body: Jason.encode!(%{body | "data" => [invalid | rest]})}

        assert_raise ExUnit.AssertionError, fn ->
          assert_api_response(malformed, "listOrganizationWorkspaces")
        end
      end
    end

    test "listOrganizations and listOrganizationWorkspaces", context do
      context.conn |> get(~p"/api/v1/organizations") |> assert_api_response("listOrganizations")

      context.conn
      |> get(~p"/api/v1/organizations/#{context.organization.id}/workspaces")
      |> assert_api_response("listOrganizationWorkspaces")

      context.conn
      |> get(~p"/api/v1/organizations/#{Ecto.UUID.generate()}/workspaces")
      |> assert_api_response("listOrganizationWorkspaces")
    end

    test "listAuditEvents", context do
      context.conn
      |> get(~p"/api/v1/organizations/#{context.organization.id}/audit-events?limit=1")
      |> assert_api_response("listAuditEvents")
    end

    test "recoverWorkspaceAccess", context do
      member = user_fixture()

      {:ok, _memberships} =
        Organizations.add_organization_member(context.scope, context.organization, member)

      {:ok, workspace} =
        Organizations.create_workspace(context.scope, context.organization, %{
          name: "Contract recovery",
          slug: "contract-recovery",
          visibility: "private"
        })

      {:ok, _membership} =
        Organizations.add_workspace_member(context.scope, workspace, member, "owner")

      {:ok, _membership} = Organizations.leave_workspace(context.scope, workspace)

      context.conn
      |> post(~p"/api/v1/workspaces/#{workspace.id}/recovery")
      |> assert_api_response("recoverWorkspaceAccess")

      context.conn
      |> post(~p"/api/v1/workspaces/#{Ecto.UUID.generate()}/recovery")
      |> assert_api_response("recoverWorkspaceAccess")
    end
  end

  describe "pastes in the personal workspace" do
    setup :api_user

    test "rejects incomplete and mixed paste content representations", %{conn: conn, scope: scope} do
      {:ok, paste} = Pastes.create_paste(scope, %{data: "text"})
      response = get(conn, ~p"/api/v1/pastes/#{paste.id}")
      body = json_response(response, 200)
      metadata = Map.delete(body["data"], "data")

      for fields <- [
            %{"data" => nil},
            %{"data" => nil, "data_base64" => "AP8BAg=="},
            %{"data" => nil, "data_encoding" => "base64"},
            %{"data" => "text", "data_base64" => "AP8BAg==", "data_encoding" => "base64"}
          ] do
        malformed = %{
          response
          | resp_body: Jason.encode!(%{"data" => Map.merge(metadata, fields)})
        }

        assert_raise ExUnit.AssertionError, fn -> assert_api_response(malformed, "getPaste") end
      end
    end

    test "create, list, show and delete", %{conn: conn} do
      created =
        conn
        |> post(~p"/api/v1/pastes", %{
          data: "hello",
          title: "Greeting",
          reference_url: "https://example.com/ticket/1",
          expires_in: "1d"
        })
        |> assert_api_response("createPaste")

      id = json_response(created, 201)["data"]["id"]

      binary =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> post(~p"/api/v1/pastes?title=Bytes", <<0, 255, 1, 2>>)
        |> assert_api_response("createPaste")

      binary_id = json_response(binary, 201)["data"]["id"]
      conn |> get(~p"/api/v1/pastes/#{binary_id}") |> assert_api_response("getPaste")

      conn |> post(~p"/api/v1/pastes", %{data: ""}) |> assert_api_response("createPaste")
      conn |> get(~p"/api/v1/pastes") |> assert_api_response("listPastes")
      conn |> get(~p"/api/v1/pastes/#{id}") |> assert_api_response("getPaste")
      conn |> get(~p"/api/v1/pastes/not-a-uuid") |> assert_api_response("getPaste")
      conn |> get(~p"/api/v1/pastes/#{Ecto.UUID.generate()}") |> assert_api_response("getPaste")
      conn |> delete(~p"/api/v1/pastes/#{id}") |> assert_api_response("deletePaste")
      build_conn() |> get(~p"/api/v1/pastes") |> assert_api_response("listPastes")
    end

    test "list, restore and purge removed pastes", %{conn: conn, scope: scope} do
      {:ok, paste} = Pastes.create_paste(scope, %{data: "gone for now"})
      {:ok, _removed} = Pastes.delete_paste(scope, paste)

      conn |> get(~p"/api/v1/pastes/deleted") |> assert_api_response("listRemovedPastes")

      conn
      |> post(~p"/api/v1/pastes/deleted/#{paste.id}/restore")
      |> assert_api_response("restorePaste")

      conn
      |> post(~p"/api/v1/pastes/deleted/#{paste.id}/restore")
      |> assert_api_response("restorePaste")

      {:ok, _removed} = Pastes.delete_paste(scope, paste)
      conn |> delete(~p"/api/v1/pastes/deleted/#{paste.id}") |> assert_api_response("purgePaste")
      conn |> delete(~p"/api/v1/pastes/deleted/#{paste.id}") |> assert_api_response("purgePaste")
      conn |> delete(~p"/api/v1/pastes/deleted/not-a-uuid") |> assert_api_response("purgePaste")
    end

    test "getRawPaste", %{scope: scope} do
      {:ok, paste} = Pastes.create_paste(scope, %{data: "shared", audience: "unlisted"})

      build_conn() |> get(~p"/pastes/#{paste.id}/raw") |> assert_api_response("getRawPaste")

      build_conn()
      |> get(~p"/pastes/#{Ecto.UUID.generate()}/raw")
      |> assert_api_response("getRawPaste")
    end
  end

  describe "pastes in a named workspace" do
    setup [:api_user, :team_organization]

    test "create, list, show and delete", %{conn: conn, workspace: workspace} do
      created =
        conn
        |> post(~p"/api/v1/workspaces/#{workspace.id}/pastes", %{data: "team note"})
        |> assert_api_response("createPasteInWorkspace")

      id = json_response(created, 201)["data"]["id"]

      conn
      |> get(~p"/api/v1/workspaces/#{workspace.id}/pastes")
      |> assert_api_response("listPastesInWorkspace")

      conn
      |> get(~p"/api/v1/workspaces/#{Ecto.UUID.generate()}/pastes")
      |> assert_api_response("listPastesInWorkspace")

      conn
      |> get(~p"/api/v1/workspaces/#{workspace.id}/pastes/#{id}")
      |> assert_api_response("getPasteInWorkspace")

      conn
      |> delete(~p"/api/v1/workspaces/#{workspace.id}/pastes/#{id}")
      |> assert_api_response("deletePasteInWorkspace")

      conn
      |> get(~p"/api/v1/workspaces/#{workspace.id}/pastes/deleted")
      |> assert_api_response("listRemovedPastesInWorkspace")

      conn
      |> post(~p"/api/v1/workspaces/#{workspace.id}/pastes/deleted/#{id}/restore")
      |> assert_api_response("restorePasteInWorkspace")

      conn
      |> delete(~p"/api/v1/workspaces/#{workspace.id}/pastes/#{id}")
      |> assert_api_response("deletePasteInWorkspace")

      conn
      |> delete(~p"/api/v1/workspaces/#{workspace.id}/pastes/deleted/#{id}")
      |> assert_api_response("purgePasteInWorkspace")
    end
  end

  defp api_user(_context) do
    user = user_fixture()
    {:ok, {token, _user_token}} = Accounts.create_user_api_token(user, %{"name" => "Contract"})

    %{
      user: user,
      scope: user_scope_fixture(user),
      conn: put_req_header(build_conn(), "authorization", "Bearer #{token}")
    }
  end

  defp team_organization(%{scope: scope}) do
    {:ok, organization} =
      Organizations.create_organization(scope, %{
        name: "Contract organization",
        slug: "contract-#{System.unique_integer([:positive])}"
      })

    {:ok, workspace} =
      Organizations.create_workspace(scope, organization, %{
        name: "Contract workspace",
        slug: "contract-workspace",
        visibility: "open"
      })

    %{organization: organization, workspace: workspace}
  end

  defp references(%Reference{"$ref": ref}), do: [ref]
  defp references(%_struct{} = struct), do: struct |> Map.from_struct() |> references()
  defp references(map) when is_map(map), do: Enum.flat_map(Map.values(map), &references/1)
  defp references(list) when is_list(list), do: Enum.flat_map(list, &references/1)
  defp references(_value), do: []
end
