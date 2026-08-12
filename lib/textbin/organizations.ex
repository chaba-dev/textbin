defmodule Textbin.Organizations do
  @moduledoc """
  Organization, workspace, and membership lifecycle boundaries.

  Membership mutations serialize on the organization and its workspaces so
  authorization and final-owner checks use current, locked state. Callers must
  use this context to keep default-workspace membership synchronized.
  """

  import Ecto.Query, warn: false

  alias Textbin.Accounts.{Scope, User}
  alias Textbin.Organizations.{Organization, OrganizationMembership, Policy}
  alias Textbin.Organizations.{Workspace, WorkspaceMembership}
  alias Textbin.Repo

  def create_organization(%Scope{user: %User{} = creator}, attrs) do
    with {:ok, creator_id} <- public_id(creator.id) do
      creator = %{creator | id: creator_id}

      %Organization{kind: "team"}
      |> Organization.changeset(attrs)
      |> create_with_default_workspace(creator)
    end
  end

  def create_organization(_, _), do: {:error, :not_found}

  def create_personal_organization(%User{} = user) do
    Repo.transact(fn -> create_personal_organization_in_transaction(user) end)
  end

  @doc "Transaction-free provisioning entry point for the Accounts outer transaction."
  def create_personal_organization_in_transaction(%User{} = user) do
    unless Repo.in_transaction?() do
      raise ArgumentError,
            "create_personal_organization_in_transaction/1 must be called inside a Repo transaction"
    end

    with {:ok, user_id} <- public_id(user.id) do
      case Repo.get_by(Organization, personal_owner_id: user_id) do
        %Organization{} = organization ->
          {:ok, preload_organization(organization)}

        nil ->
          user = %{user | id: user_id}

          %Organization{kind: "personal", personal_owner_id: user_id}
          |> Organization.changeset(%{name: "Personal", slug: "personal-#{user_id}"})
          |> create_with_default_workspace_in_transaction(user)
      end
    end
  end

  def get_personal_organization!(%User{id: id}) do
    Organization |> Repo.get_by!(personal_owner_id: id) |> preload_organization()
  end

  def get_personal_default_workspace!(%User{id: id}) do
    Repo.one!(
      from w in Workspace,
        join: o in Organization,
        on: o.id == w.organization_id,
        where: o.personal_owner_id == ^id and w.is_default
    )
  end

  @doc "Resolves a workspace and both memberships without disclosing inaccessible records."
  def resolve_workspace_scope(%Scope{user: %User{id: user_id}} = scope, workspace_or_id) do
    with {:ok, user_id} <- public_id(user_id),
         {:ok, id} <- public_id(record_id(workspace_or_id)) do
      query =
        from w in Workspace,
          join: o in assoc(w, :organization),
          join: om in OrganizationMembership,
          on: om.organization_id == o.id and om.user_id == ^user_id,
          join: wm in WorkspaceMembership,
          on: wm.workspace_id == w.id and wm.user_id == ^user_id,
          where: w.id == ^id,
          select: {o, om, w, wm}

      case Repo.one(query) do
        {o, om, w, wm} ->
          {:ok,
           %{
             scope
             | organization: o,
               organization_membership: om,
               workspace: w,
               workspace_membership: wm
           }}

        nil ->
          {:error, :not_found}
      end
    end
  end

  def resolve_workspace_scope(_, _), do: {:error, :not_found}

  def add_organization_member(
        %Scope{} = scope,
        %Organization{} = organization,
        %User{} = user,
        role \\ Policy.organization_member_role()
      ) do
    with {:ok, organization_id} <- public_id(organization.id),
         {:ok, user_id} <- public_id(user.id) do
      organization_transaction(scope, organization_id, fn actor, _workspaces ->
        with :ok <- Policy.authorize_organization_change(actor, nil, role),
             {:ok, om} <- insert_organization_membership(organization_id, user_id, role),
             %Workspace{} = workspace <- get_default_workspace(organization_id),
             {:ok, wm} <-
               insert_workspace_membership(
                 workspace.id,
                 user_id,
                 Policy.workspace_member_role(),
                 actor.user_id
               ) do
          {:ok, %{organization: om, workspace: wm}}
        else
          nil -> {:error, :default_workspace_not_found}
          error -> error
        end
      end)
    end
  end

  def change_organization_member_role(%Scope{} = scope, %OrganizationMembership{} = target, role) do
    organization_transaction(scope, target.organization_id, fn actor, _ ->
      with %OrganizationMembership{} = fresh <- organization_membership(target),
           :ok <- Policy.authorize_organization_change(actor, fresh.role, role),
           :ok <- preserve_organization_owner(fresh, role) do
        fresh |> OrganizationMembership.role_changeset(%{role: role}) |> Repo.update()
      else
        nil -> {:error, :not_found}
        error -> error
      end
    end)
  end

  def remove_organization_member(%Scope{} = scope, %OrganizationMembership{} = target),
    do: remove_organization(scope, target, false)

  def leave_organization(%Scope{user: %User{}} = scope, %Organization{} = organization) do
    target = %OrganizationMembership{organization_id: organization.id, user_id: scope.user.id}
    remove_organization(scope, target, true)
  end

  def leave_organization(_, _), do: {:error, :not_found}

  def add_workspace_member(
        %Scope{} = scope,
        %Workspace{} = workspace,
        %User{} = user,
        role \\ Policy.workspace_member_role()
      ) do
    with {:ok, user_id} <- public_id(user.id) do
      workspace_transaction(scope, workspace, fn _org_actor, actor, fresh_workspace ->
        with :ok <- Policy.authorize_workspace_change(actor),
             %OrganizationMembership{} <-
               Repo.get_by(OrganizationMembership,
                 organization_id: fresh_workspace.organization_id,
                 user_id: user_id
               ) do
          insert_workspace_membership(fresh_workspace.id, user_id, role, actor.user_id)
        else
          nil -> {:error, :not_found}
          error -> error
        end
      end)
    end
  end

  def change_workspace_member_role(%Scope{} = scope, %WorkspaceMembership{} = target, role) do
    with %Workspace{} = workspace <- workspace_for_membership(target) do
      workspace_transaction(scope, workspace, fn _, actor, fresh_workspace ->
        with %WorkspaceMembership{} = fresh <- workspace_membership(target),
             %OrganizationMembership{} <-
               organization_membership_for(fresh_workspace.organization_id, fresh.user_id),
             :ok <- Policy.authorize_workspace_change(actor),
             :ok <- preserve_workspace_owner(fresh, role) do
          fresh |> WorkspaceMembership.role_changeset(%{role: role}) |> Repo.update()
        else
          nil -> {:error, :not_found}
          error -> error
        end
      end)
    else
      nil -> {:error, :not_found}
    end
  end

  def remove_workspace_member(%Scope{} = scope, %WorkspaceMembership{} = target),
    do: remove_workspace(scope, target, false)

  def leave_workspace(%Scope{user: %User{id: user_id}} = scope, %Workspace{} = workspace) do
    remove_workspace(
      scope,
      %WorkspaceMembership{workspace_id: workspace.id, user_id: user_id},
      true
    )
  end

  def leave_workspace(_, _), do: {:error, :not_found}

  defp remove_organization(scope, target, leaving?) do
    organization_transaction(scope, target.organization_id, fn actor, workspaces ->
      with %OrganizationMembership{} = fresh <- organization_membership(target),
           :ok <- authorize_org_removal(actor, fresh, leaving?),
           :ok <- preserve_organization_owner(fresh, nil),
           :ok <- preserve_owned_workspaces(fresh.user_id, workspaces) do
        Repo.delete_all(
          from wm in WorkspaceMembership,
            where:
              wm.user_id == ^fresh.user_id and wm.workspace_id in ^Enum.map(workspaces, & &1.id)
        )

        Repo.delete(fresh)
      else
        nil -> {:error, :not_found}
        error -> error
      end
    end)
  end

  defp remove_workspace(scope, target, leaving?) do
    with %Workspace{} = workspace <- workspace_for_membership(target) do
      workspace_transaction(scope, workspace, fn _, actor, fresh_workspace ->
        with %WorkspaceMembership{} = fresh <- workspace_membership(target),
             %OrganizationMembership{} <-
               organization_membership_for(fresh_workspace.organization_id, fresh.user_id),
             :ok <- authorize_workspace_removal(actor, fresh, leaving?),
             false <- fresh_workspace.is_default,
             :ok <- preserve_workspace_owner(fresh, nil) do
          Repo.delete(fresh)
        else
          true -> {:error, :default_workspace_membership_required}
          nil -> {:error, :not_found}
          error -> error
        end
      end)
    else
      nil -> {:error, :not_found}
    end
  end

  defp organization_transaction(%Scope{user: %User{id: actor_id}}, organization_id, callback) do
    with {:ok, actor_id} <- public_id(actor_id),
         {:ok, organization_id} <- public_id(organization_id) do
      Repo.transact(fn ->
        with %Organization{} <-
               Repo.one(
                 from o in Organization, where: o.id == ^organization_id, lock: "FOR UPDATE"
               ),
             workspaces <-
               Repo.all(
                 from w in Workspace,
                   where: w.organization_id == ^organization_id,
                   order_by: w.id,
                   lock: "FOR UPDATE"
               ),
             %OrganizationMembership{} = actor <-
               Repo.get_by(OrganizationMembership,
                 organization_id: organization_id,
                 user_id: actor_id
               ) do
          callback.(actor, workspaces)
        else
          nil -> {:error, :not_found}
        end
      end)
    end
  end

  defp organization_transaction(_, _, _), do: {:error, :not_found}

  defp workspace_transaction(
         scope,
         %Workspace{id: workspace_id, organization_id: organization_id},
         callback
       ) do
    with {:ok, workspace_id} <- public_id(workspace_id),
         {:ok, organization_id} <- public_id(organization_id) do
      organization_transaction(scope, organization_id, fn org_actor, workspaces ->
        with %Workspace{} = workspace <- Enum.find(workspaces, &(&1.id == workspace_id)),
             %WorkspaceMembership{} = actor <-
               Repo.get_by(WorkspaceMembership,
                 workspace_id: workspace_id,
                 user_id: scope.user.id
               ) do
          callback.(org_actor, actor, workspace)
        else
          nil -> {:error, :not_found}
        end
      end)
    end
  end

  defp preserve_organization_owner(%{role: role, organization_id: id}, new_role) do
    owner_role = Policy.organization_owner_role()

    if role == owner_role and new_role != role and
         Repo.aggregate(
           from(m in OrganizationMembership,
             where: m.organization_id == ^id and m.role == ^owner_role
           ),
           :count
         ) == 1, do: {:error, :last_organization_owner}, else: :ok
  end

  defp preserve_workspace_owner(%{role: role, workspace_id: id}, new_role) do
    owner_role = Policy.workspace_owner_role()

    if role == owner_role and new_role != role and
         Repo.aggregate(
           from(m in WorkspaceMembership, where: m.workspace_id == ^id and m.role == ^owner_role),
           :count
         ) == 1, do: {:error, :last_workspace_owner}, else: :ok
  end

  defp preserve_owned_workspaces(user_id, workspaces) do
    owner_role = Policy.workspace_owner_role()

    final? =
      Enum.any?(workspaces, fn w ->
        Repo.get_by(WorkspaceMembership, workspace_id: w.id, user_id: user_id, role: owner_role) &&
          Repo.aggregate(
            from(m in WorkspaceMembership,
              where: m.workspace_id == ^w.id and m.role == ^owner_role
            ),
            :count
          ) == 1
      end)

    if final?, do: {:error, :last_workspace_owner}, else: :ok
  end

  defp authorize_org_removal(actor, target, true) when actor.user_id == target.user_id, do: :ok

  defp authorize_org_removal(actor, target, _),
    do: Policy.authorize_organization_change(actor, target.role)

  defp authorize_workspace_removal(actor, target, true) when actor.user_id == target.user_id,
    do: :ok

  defp authorize_workspace_removal(actor, _target, _),
    do: Policy.authorize_workspace_change(actor)

  defp organization_membership(m) do
    with {:ok, organization_id} <- public_id(m.organization_id),
         {:ok, user_id} <- public_id(m.user_id),
         {:ok, id_filter} <- optional_id_filter(m.id) do
      Repo.get_by(
        OrganizationMembership,
        [organization_id: organization_id, user_id: user_id] ++ id_filter
      )
    else
      _ -> nil
    end
  end

  defp workspace_membership(m) do
    with {:ok, workspace_id} <- public_id(m.workspace_id),
         {:ok, user_id} <- public_id(m.user_id),
         {:ok, id_filter} <- optional_id_filter(m.id) do
      Repo.get_by(
        WorkspaceMembership,
        [workspace_id: workspace_id, user_id: user_id] ++ id_filter
      )
    else
      _ -> nil
    end
  end

  defp workspace_for_membership(%{workspace_id: id}) do
    with {:ok, id} <- public_id(id), do: Repo.get(Workspace, id), else: (_ -> nil)
  end

  defp organization_membership_for(organization_id, user_id) do
    Repo.get_by(OrganizationMembership, organization_id: organization_id, user_id: user_id)
  end

  defp record_id(%{id: id}), do: id
  defp record_id(id), do: id

  defp public_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp optional_id_filter(nil), do: {:ok, []}
  defp optional_id_filter(id), do: with({:ok, id} <- public_id(id), do: {:ok, [id: id]})

  defp create_with_default_workspace(changeset, creator),
    do: Repo.transact(fn -> create_with_default_workspace_in_transaction(changeset, creator) end)

  defp create_with_default_workspace_in_transaction(changeset, creator) do
    with {:ok, organization} <- Repo.insert(changeset),
         {:ok, _} <-
           insert_organization_membership(
             organization.id,
             creator.id,
             Policy.organization_owner_role()
           ),
         {:ok, workspace} <- insert_default_workspace(organization.id, creator.id),
         {:ok, _} <-
           insert_workspace_membership(
             workspace.id,
             creator.id,
             Policy.workspace_owner_role(),
             creator.id
           ),
         do: {:ok, preload_organization(organization)}
  end

  defp preload_organization(o), do: Repo.preload(o, [:memberships, workspaces: :memberships])

  defp insert_organization_membership(oid, uid, role),
    do:
      %OrganizationMembership{organization_id: oid, user_id: uid, role: role}
      |> OrganizationMembership.changeset()
      |> Repo.insert()

  defp insert_default_workspace(oid, uid),
    do:
      %Workspace{organization_id: oid, created_by_id: uid, is_default: true}
      |> Workspace.changeset(%{name: "Default", slug: "default", visibility: "open"})
      |> Repo.insert()

  defp insert_workspace_membership(wid, uid, role, by),
    do:
      %WorkspaceMembership{workspace_id: wid, user_id: uid, role: role, created_by_id: by}
      |> WorkspaceMembership.changeset()
      |> Repo.insert()

  defp get_default_workspace(oid),
    do: Repo.get_by(Workspace, organization_id: oid, is_default: true)
end
