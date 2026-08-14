defmodule TextbinWeb.ApiV1.OrganizationJSON do
  alias Textbin.Organizations.{Organization, Workspace}

  def index(%{organizations: organizations}) do
    %{data: for(organization <- organizations, do: organization_data(organization))}
  end

  def workspaces(%{organization: organization, workspaces: workspaces}) do
    %{
      data: for(workspace <- workspaces, do: workspace_data(workspace)),
      organization: organization_data(organization)
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
end
