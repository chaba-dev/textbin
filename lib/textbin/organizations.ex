defmodule Textbin.Organizations do
  @moduledoc """
  Organization, workspace, and membership lifecycle boundaries.

  Every organization has one open default workspace. Organization membership
  changes must go through this context so its explicit default-workspace
  membership remains synchronized.
  """

  import Ecto.Query, warn: false

  alias Textbin.Accounts.{Scope, User}
  alias Textbin.Organizations.Organization
  alias Textbin.Organizations.OrganizationMembership
  alias Textbin.Organizations.Workspace
  alias Textbin.Organizations.WorkspaceMembership
  alias Textbin.Repo

  @doc """
  Creates a team organization and its default workspace for the creator.
  """
  def create_organization(%Scope{user: %User{} = creator}, attrs) do
    organization_changeset =
      %Organization{kind: "team"}
      |> Organization.changeset(attrs)

    create_with_default_workspace(organization_changeset, creator)
  end

  @doc """
  Creates the personal organization and default workspace for a new user.

  This is called from the user-creation transaction and is public to keep the
  provisioning boundary explicit and directly testable.
  """
  def create_personal_organization(%User{} = user) do
    case Repo.get_by(Organization, personal_owner_id: user.id) do
      %Organization{} = organization ->
        {:ok, preload_organization(organization)}

      nil ->
        organization_changeset =
          %Organization{kind: "personal", personal_owner_id: user.id}
          |> Organization.changeset(%{
            name: "Personal",
            slug: "personal-#{user.id}"
          })

        create_with_default_workspace(organization_changeset, user)
    end
  end

  def get_personal_organization!(%User{id: user_id}) do
    Organization
    |> Repo.get_by!(personal_owner_id: user_id)
    |> preload_organization()
  end

  @doc """
  Adds a user to an organization and its default workspace atomically.
  """
  def add_organization_member(
        %Scope{user: %User{id: actor_id}},
        %Organization{id: organization_id},
        %User{} = user,
        role \\ "member"
      ) do
    Repo.transact(fn ->
      with :ok <- authorize_membership_management(organization_id, actor_id),
           {:ok, organization_membership} <-
             insert_organization_membership(organization_id, user.id, role),
           %Workspace{} = workspace <- get_default_workspace(organization_id),
           {:ok, workspace_membership} <-
             insert_workspace_membership(workspace.id, user.id, "member", actor_id) do
        {:ok, %{organization: organization_membership, workspace: workspace_membership}}
      else
        nil -> {:error, :default_workspace_not_found}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp authorize_membership_management(organization_id, actor_id) do
    membership =
      Repo.one(
        from membership in OrganizationMembership,
          where:
            membership.organization_id == ^organization_id and
              membership.user_id == ^actor_id,
          lock: "FOR SHARE"
      )

    case membership do
      %OrganizationMembership{role: role} when role in ["owner", "admin"] -> :ok
      %OrganizationMembership{} -> {:error, :unauthorized}
      nil -> {:error, :not_found}
    end
  end

  defp create_with_default_workspace(organization_changeset, creator) do
    Repo.transact(fn ->
      with {:ok, organization} <- Repo.insert(organization_changeset),
           {:ok, _organization_membership} <-
             insert_organization_membership(organization.id, creator.id, "owner"),
           {:ok, workspace} <- insert_default_workspace(organization.id, creator.id),
           {:ok, _workspace_membership} <-
             insert_workspace_membership(workspace.id, creator.id, "owner", creator.id) do
        {:ok, preload_organization(organization)}
      end
    end)
  end

  defp preload_organization(organization) do
    Repo.preload(organization, [:memberships, workspaces: :memberships])
  end

  defp insert_organization_membership(organization_id, user_id, role) do
    %OrganizationMembership{
      organization_id: organization_id,
      user_id: user_id,
      role: role
    }
    |> OrganizationMembership.changeset()
    |> Repo.insert()
  end

  defp insert_default_workspace(organization_id, creator_id) do
    %Workspace{
      organization_id: organization_id,
      created_by_id: creator_id,
      is_default: true
    }
    |> Workspace.changeset(%{name: "Default", slug: "default", visibility: "open"})
    |> Repo.insert()
  end

  defp insert_workspace_membership(workspace_id, user_id, role, created_by_id) do
    %WorkspaceMembership{
      workspace_id: workspace_id,
      user_id: user_id,
      role: role,
      created_by_id: created_by_id
    }
    |> WorkspaceMembership.changeset()
    |> Repo.insert()
  end

  defp get_default_workspace(organization_id) do
    Repo.one(
      from workspace in Workspace,
        where: workspace.organization_id == ^organization_id and workspace.is_default
    )
  end
end
