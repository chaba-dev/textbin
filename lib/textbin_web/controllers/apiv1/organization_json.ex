defmodule TextbinWeb.ApiV1.OrganizationJSON do
  alias Textbin.Organizations.{AuditEvent, Organization, Workspace, WorkspaceMembership}

  def index(%{organizations: organizations}) do
    %{data: for(organization <- organizations, do: organization_data(organization))}
  end

  def workspaces(%{organization: organization, workspaces: workspaces}) do
    %{
      data: for(workspace <- workspaces, do: workspace_data(workspace)),
      organization: organization_data(organization)
    }
  end

  def audit_events(%{events: events}) do
    %{data: for(event <- events, do: audit_event_data(event))}
  end

  def recovery(%{membership: %WorkspaceMembership{} = membership}) do
    %{
      data: %{
        workspace_id: membership.workspace_id,
        user_id: membership.user_id,
        role: membership.role
      }
    }
  end

  defp organization_data(%Organization{} = organization) do
    %{
      id: organization.id,
      name: organization.name,
      slug: organization.slug,
      kind: organization.kind
    }
  end

  defp workspace_data(%Workspace{} = workspace) do
    %{
      id: workspace.id,
      organization_id: workspace.organization_id,
      name: workspace.name,
      slug: workspace.slug,
      visibility: workspace.visibility,
      external_sharing_policy: workspace.external_sharing_policy,
      is_default: workspace.is_default
    }
  end

  defp audit_event_data(%AuditEvent{} = event) do
    %{
      id: event.id,
      actor_user_id: event.actor_user_id,
      action: event.action,
      target_type: event.target_type,
      target_id: event.target_id,
      metadata: event.metadata,
      inserted_at: DateTime.to_iso8601(event.inserted_at)
    }
  end
end
