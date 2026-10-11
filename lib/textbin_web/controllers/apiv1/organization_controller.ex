defmodule TextbinWeb.ApiV1.OrganizationController do
  use TextbinWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import TextbinWeb.ApiDocs

  alias OpenApiSpex.Schema
  alias Textbin.Accounts.Scope
  alias Textbin.Organizations

  tags ["Organizations"]

  plug TextbinWeb.ApiRequestValidation

  operation :index,
    operation_id: "listOrganizations",
    summary: "List the organizations you belong to",
    responses: with_common_errors(%{200 => response("Organizations", "OrganizationList")})

  def index(conn, _params) do
    with_api_scope(conn, fn scope ->
      render(conn, :index, organizations: Organizations.list_available_organizations(scope))
    end)
  end

  operation :workspaces,
    operation_id: "listOrganizationWorkspaces",
    summary: "List workspaces you have joined or can join",
    parameters: [id: uuid_path("Organization id")],
    responses:
      with_common_errors(%{
        200 => response("The organization and its workspaces", "WorkspaceList"),
        404 => error("Organization not found")
      })

  def workspaces(conn, %{"id" => id}) do
    with_api_scope(conn, fn scope ->
      with %{} = organization <- Organizations.get_available_organization(scope, id),
           {:ok, workspaces} <- Organizations.list_available_workspaces(scope, organization) do
        render(conn, :workspaces, organization: organization, workspaces: workspaces)
      else
        _error ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "Organization not found"}})
      end
    end)
  end

  operation :audit_events,
    operation_id: "listAuditEvents",
    summary: "Page through an organization's audit log",
    parameters: [
      id: uuid_path("Organization id"),
      limit: query(%Schema{type: :integer, minimum: 1}, "Events per page"),
      cursor: query(%Schema{type: :string}, "next_cursor from the previous page")
    ],
    responses:
      with_common_errors(%{
        200 => response("A page of audit events", "AuditEventPage"),
        404 => error("Organization not found, or you cannot read its audit log")
      })

  def audit_events(conn, %{"id" => id}) do
    with_api_scope(conn, fn scope ->
      with %{} = organization <- Organizations.get_available_organization(scope, id),
           {:ok, page} <-
             Organizations.list_audit_event_page(scope, organization,
               limit: conn.params["limit"],
               cursor: conn.params["cursor"]
             ) do
        render(conn, :audit_events, events: page.events, next_cursor: page.next_cursor)
      else
        _error ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "Organization not found"}})
      end
    end)
  end

  operation :recover_workspace,
    operation_id: "recoverWorkspaceAccess",
    summary: "Make yourself owner of a workspace in an organization you own",
    parameters: [workspace_id: uuid_path("Workspace id")],
    responses:
      with_common_errors(%{
        201 => response("Your new membership", "WorkspaceRecovery"),
        404 => error("Workspace not found, or you cannot recover it")
      })

  def recover_workspace(conn, %{"workspace_id" => workspace_id}) do
    with_api_scope(conn, fn scope ->
      case Organizations.recover_workspace_access(scope, workspace_id) do
        {:ok, membership} ->
          conn
          |> put_status(:created)
          |> render(:recovery, membership: membership)

        {:error, _reason} ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "Workspace not found"}})
      end
    end)
  end

  defp with_api_scope(%{assigns: %{current_scope: %Scope{user: %{}} = scope}}, fun),
    do: fun.(scope)

  defp with_api_scope(conn, _fun) do
    conn
    |> put_status(:unauthorized)
    |> json(%{errors: %{detail: "API token required"}})
  end
end
