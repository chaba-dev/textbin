defmodule TextbinWeb.ApiV1.OrganizationController do
  use TextbinWeb, :controller

  alias Textbin.Accounts.Scope
  alias Textbin.Organizations

  def index(conn, _params) do
    with_api_scope(conn, fn scope ->
      render(conn, :index, organizations: Organizations.list_available_organizations(scope))
    end)
  end

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

  def audit_events(conn, %{"id" => id}) do
    with_api_scope(conn, fn scope ->
      with %{} = organization <- Organizations.get_available_organization(scope, id),
           {:ok, events} <- Organizations.list_audit_events(scope, organization) do
        render(conn, :audit_events, events: events)
      else
        _error ->
          conn
          |> put_status(:not_found)
          |> json(%{errors: %{detail: "Organization not found"}})
      end
    end)
  end

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
