defmodule Textbin.Organizations.Policy do
  @moduledoc "Pure authorization rules for organization and workspace membership lifecycle."

  alias Textbin.Organizations.{OrganizationMembership, WorkspaceMembership}

  @organization_owner "owner"
  @organization_admin "admin"
  @organization_member "member"
  @workspace_owner "owner"
  @workspace_member "member"

  def organization_owner_role, do: @organization_owner
  def organization_admin_role, do: @organization_admin
  def organization_member_role, do: @organization_member
  def workspace_owner_role, do: @workspace_owner
  def workspace_member_role, do: @workspace_member

  def organization_owner?(%OrganizationMembership{role: @organization_owner}), do: true
  def organization_owner?(_), do: false
  def workspace_owner?(%WorkspaceMembership{role: @workspace_owner}), do: true
  def workspace_owner?(_), do: false

  def authorize_organization_change(actor, target_role, new_role \\ nil) do
    cond do
      actor.role not in [@organization_owner, @organization_admin] ->
        {:error, :unauthorized}

      @organization_owner in [target_role, new_role] and not organization_owner?(actor) ->
        {:error, :unauthorized}

      true ->
        :ok
    end
  end

  def authorize_workspace_change(actor) do
    if workspace_owner?(actor), do: :ok, else: {:error, :unauthorized}
  end
end
