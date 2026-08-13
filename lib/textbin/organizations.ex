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
  alias Textbin.Pastes.Paste
  alias Textbin.Repo

  def create_organization(%Scope{user: %User{} = creator}, attrs) do
    ensure_transaction_owner!()

    with {:ok, creator_id} <- public_id(creator.id) do
      creator = %{creator | id: creator_id}

      %Organization{kind: "team"}
      |> Organization.changeset(attrs)
      |> create_with_default_workspace(creator)
    end
  end

  def create_organization(_, _), do: {:error, :not_found}

  def create_personal_organization(%User{} = user) do
    ensure_transaction_owner!()
    Repo.transact(fn -> create_personal_organization_in_transaction(user) end)
  end

  def create_personal_organization(_), do: {:error, :not_found}

  @doc "Transaction-free provisioning entry point for the Accounts outer transaction."
  def create_personal_organization_in_transaction(%User{} = user) do
    unless Repo.in_transaction?() do
      raise ArgumentError,
            "create_personal_organization_in_transaction/1 must be called inside a Repo transaction"
    end

    with {:ok, user_id} <- public_id(user.id),
         {:ok, user} <- lock_existing_user(user_id) do
      case Repo.get_by(Organization, personal_owner_id: user_id) do
        %Organization{} = organization ->
          {:ok, preload_organization(organization)}

        nil ->
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

  @doc "Resolves an explicitly joined workspace from its stable URL slugs."
  def resolve_workspace_scope_by_slugs(
        %Scope{user: %User{id: user_id}} = scope,
        organization_slug,
        workspace_slug
      )
      when is_binary(organization_slug) and is_binary(workspace_slug) do
    query =
      from workspace in Workspace,
        join: organization in assoc(workspace, :organization),
        join: organization_membership in OrganizationMembership,
        on:
          organization_membership.organization_id == organization.id and
            organization_membership.user_id == ^user_id,
        join: workspace_membership in WorkspaceMembership,
        on:
          workspace_membership.workspace_id == workspace.id and
            workspace_membership.user_id == ^user_id,
        where: organization.slug == ^organization_slug and workspace.slug == ^workspace_slug,
        select: {organization, organization_membership, workspace, workspace_membership}

    case Repo.one(query) do
      {organization, organization_membership, workspace, workspace_membership} ->
        {:ok,
         %{
           scope
           | organization: organization,
             organization_membership: organization_membership,
             workspace: workspace,
             workspace_membership: workspace_membership
         }}

      nil ->
        {:error, :not_found}
    end
  end

  def resolve_workspace_scope_by_slugs(_, _, _), do: {:error, :not_found}

  def list_available_organizations(%Scope{user: %User{id: user_id}}) do
    Repo.all(
      from organization in Organization,
        join: membership in OrganizationMembership,
        on: membership.organization_id == organization.id,
        where: membership.user_id == ^user_id,
        order_by: [asc: organization.name, asc: organization.id]
    )
  end

  def list_available_organizations(_scope), do: []

  def list_joined_workspaces(
        %Scope{user: %User{id: user_id}},
        %Organization{id: organization_id}
      ) do
    Repo.all(
      from workspace in Workspace,
        join: membership in WorkspaceMembership,
        on: membership.workspace_id == workspace.id,
        where: workspace.organization_id == ^organization_id and membership.user_id == ^user_id,
        order_by: [desc: workspace.is_default, asc: workspace.name, asc: workspace.id]
    )
  end

  def list_joined_workspaces(_scope, _organization), do: []

  def list_workspace_members(%Scope{workspace: %Workspace{id: workspace_id}} = scope) do
    case resolve_workspace_scope(scope, workspace_id) do
      {:ok, _resolved_scope} ->
        Repo.all(
          from membership in WorkspaceMembership,
            join: user in assoc(membership, :user),
            where: membership.workspace_id == ^workspace_id,
            preload: [user: user],
            order_by: [asc: membership.role, asc: user.email, asc: membership.id]
        )

      {:error, :not_found} ->
        []
    end
  end

  def list_workspace_members(_scope), do: []

  def get_workspace_member(
        %Scope{workspace: %Workspace{id: workspace_id}} = scope,
        membership_id
      ) do
    with {:ok, _resolved_scope} <- resolve_workspace_scope(scope, workspace_id),
         {:ok, id} <- Ecto.UUID.cast(membership_id) do
      WorkspaceMembership
      |> Repo.get_by(id: id, workspace_id: workspace_id)
      |> Repo.preload(:user)
    else
      _error ->
        nil
    end
  end

  def get_workspace_member(_scope, _membership_id), do: nil

  def create_workspace(
        %Scope{} = scope,
        %Organization{} = organization,
        attrs
      )
      when is_map(attrs) do
    organization_transaction(scope, organization.id, fn fresh_organization, actor, _workspaces ->
      with :ok <- Policy.authorize_workspace_creation(actor),
           {:ok, workspace} <-
             %Workspace{
               organization_id: fresh_organization.id,
               created_by_id: actor.user_id,
               is_default: false
             }
             |> Workspace.changeset(attrs)
             |> Repo.insert(),
           {:ok, _membership} <-
             insert_workspace_membership(
               workspace.id,
               actor.user_id,
               Policy.workspace_owner_role(),
               actor.user_id
             ) do
        {:ok, Repo.preload(workspace, :memberships)}
      end
    end)
  end

  def create_workspace(_, _, _), do: {:error, :not_found}

  def list_available_workspaces(
        %Scope{user: %User{id: user_id}},
        %Organization{id: organization_id}
      ) do
    with {:ok, user_id} <- public_id(user_id),
         {:ok, organization_id} <- public_id(organization_id) do
      workspaces =
        Repo.all(
          from workspace in Workspace,
            join: organization_membership in OrganizationMembership,
            on:
              organization_membership.organization_id == workspace.organization_id and
                organization_membership.user_id == ^user_id,
            left_join: workspace_membership in WorkspaceMembership,
            on:
              workspace_membership.workspace_id == workspace.id and
                workspace_membership.user_id == ^user_id,
            where:
              workspace.organization_id == ^organization_id and
                (workspace.visibility == "open" or not is_nil(workspace_membership.id)),
            order_by: [desc: workspace.is_default, asc: workspace.name, asc: workspace.id]
        )

      if workspaces == [], do: {:error, :not_found}, else: {:ok, workspaces}
    else
      error -> error
    end
  end

  def list_available_workspaces(_, _), do: {:error, :not_found}

  def join_workspace(
        %Scope{user: %User{id: user_id}} = scope,
        %Workspace{id: workspace_id, organization_id: organization_id}
      ) do
    with {:ok, user_id} <- public_id(user_id),
         {:ok, workspace_id} <- public_id(workspace_id),
         {:ok, organization_id} <- public_id(organization_id) do
      organization_transaction(
        scope,
        organization_id,
        &join_workspace_in_transaction(&1, &2, &3, workspace_id, user_id)
      )
    end
  end

  def join_workspace(_, _), do: {:error, :not_found}

  def change_workspace_visibility(%Scope{} = scope, %Workspace{} = workspace, visibility) do
    change_workspace_settings(scope, workspace, %{visibility: visibility})
  end

  def change_workspace_visibility(_, _, _), do: {:error, :not_found}

  def change_workspace_settings(%Scope{} = scope, %Workspace{} = workspace, attrs)
      when is_map(attrs) do
    workspace_transaction(
      scope,
      workspace,
      &change_workspace_settings_in_transaction(&1, &2, &3, &4, attrs)
    )
  end

  def change_workspace_settings(_, _, _), do: {:error, :not_found}

  def delete_workspace(%Scope{} = scope, %Workspace{} = workspace) do
    workspace_transaction(scope, workspace, &delete_workspace_in_transaction/4)
  end

  def delete_workspace(_, _), do: {:error, :not_found}

  def add_organization_member(
        scope,
        organization,
        user,
        role \\ Policy.organization_member_role()
      )

  def add_organization_member(
        %Scope{} = scope,
        %Organization{} = organization,
        %User{} = user,
        role
      ) do
    with {:ok, organization_id} <- public_id(organization.id),
         {:ok, user_id} <- public_id(user.id) do
      organization_transaction(
        scope,
        organization_id,
        &add_organization_member_in_transaction(&1, &2, &3, organization_id, user_id, role)
      )
    end
  end

  def add_organization_member(_, _, _, _), do: {:error, :not_found}

  def change_organization_member_role(%Scope{} = scope, %OrganizationMembership{} = target, role) do
    organization_transaction(scope, target.organization_id, fn organization, actor, _ ->
      with %OrganizationMembership{} = fresh <- organization_membership(target),
           :ok <- Policy.authorize_organization_change(actor, fresh.role, role),
           :ok <- preserve_personal_owner(organization, fresh, role),
           :ok <- preserve_organization_owner(fresh, role) do
        fresh |> OrganizationMembership.role_changeset(%{role: role}) |> Repo.update()
      else
        nil -> {:error, :not_found}
        error -> error
      end
    end)
  end

  def change_organization_member_role(_, _, _), do: {:error, :not_found}

  def remove_organization_member(%Scope{} = scope, %OrganizationMembership{} = target),
    do: remove_organization(scope, target, false)

  def remove_organization_member(_, _), do: {:error, :not_found}

  def leave_organization(%Scope{user: %User{}} = scope, %Organization{} = organization) do
    target = %OrganizationMembership{organization_id: organization.id, user_id: scope.user.id}
    remove_organization(scope, target, true)
  end

  def leave_organization(_, _), do: {:error, :not_found}

  def add_workspace_member(scope, workspace, user, role \\ Policy.workspace_member_role())

  def add_workspace_member(
        %Scope{} = scope,
        %Workspace{} = workspace,
        %User{} = user,
        role
      ) do
    with {:ok, user_id} <- public_id(user.id) do
      workspace_transaction(
        scope,
        workspace,
        &add_workspace_member_in_transaction(&1, &2, &3, &4, user_id, role)
      )
    end
  end

  def add_workspace_member(_, _, _, _), do: {:error, :not_found}

  def change_workspace_member_role(%Scope{} = scope, %WorkspaceMembership{} = target, role) do
    case workspace_for_membership(target) do
      %Workspace{} = workspace ->
        workspace_transaction(
          scope,
          workspace,
          &change_workspace_member_role_in_transaction(&1, &2, &3, &4, target, role)
        )

      nil ->
        {:error, :not_found}
    end
  end

  def change_workspace_member_role(_, _, _), do: {:error, :not_found}

  def remove_workspace_member(%Scope{} = scope, %WorkspaceMembership{} = target),
    do: remove_workspace(scope, target, false)

  def remove_workspace_member(_, _), do: {:error, :not_found}

  def leave_workspace(%Scope{user: %User{id: user_id}} = scope, %Workspace{} = workspace) do
    remove_workspace(
      scope,
      %WorkspaceMembership{workspace_id: workspace.id, user_id: user_id},
      true
    )
  end

  def leave_workspace(_, _), do: {:error, :not_found}

  defp remove_organization(scope, target, leaving?) do
    organization_transaction(scope, target.organization_id, fn organization, actor, workspaces ->
      with %OrganizationMembership{} = fresh <- organization_membership(target, leaving?),
           :ok <- authorize_org_removal(actor, fresh, leaving?),
           :ok <- preserve_personal_owner(organization, fresh, nil),
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
    case workspace_for_membership(target) do
      %Workspace{} = workspace ->
        workspace_transaction(
          scope,
          workspace,
          &remove_workspace_in_transaction(&1, &2, &3, &4, target, leaving?)
        )

      nil ->
        {:error, :not_found}
    end
  end

  defp add_organization_member_in_transaction(
         _organization,
         actor,
         _workspaces,
         organization_id,
         user_id,
         role
       ) do
    with :ok <- Policy.authorize_organization_change(actor, nil, role),
         {:ok, _user} <- lock_existing_user(user_id),
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
  end

  defp join_workspace_in_transaction(
         _organization,
         actor,
         workspaces,
         workspace_id,
         user_id
       ) do
    with %Workspace{} = workspace <- Enum.find(workspaces, &(&1.id == workspace_id)),
         :ok <- Policy.authorize_workspace_join(workspace) do
      insert_workspace_membership(
        workspace.id,
        user_id,
        Policy.workspace_member_role(),
        actor.user_id
      )
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp change_workspace_settings_in_transaction(
         _organization,
         _org_actor,
         actor,
         workspace,
         attrs
       ) do
    with :ok <- Policy.authorize_workspace_change(actor),
         {:ok, updated_workspace} <-
           workspace
           |> Workspace.changeset(attrs)
           |> Repo.update() do
      clamp_paste_audiences(updated_workspace)
      {:ok, updated_workspace}
    end
  end

  defp clamp_paste_audiences(%Workspace{id: workspace_id, external_sharing_policy: "disabled"}) do
    Repo.update_all(
      from(paste in Paste,
        where: paste.workspace_id == ^workspace_id and paste.audience != "workspace"
      ),
      set: [audience: "workspace"]
    )
  end

  defp clamp_paste_audiences(%Workspace{id: workspace_id, external_sharing_policy: "unlisted"}) do
    Repo.update_all(
      from(paste in Paste,
        where: paste.workspace_id == ^workspace_id and paste.audience == "public"
      ),
      set: [audience: "unlisted"]
    )
  end

  defp clamp_paste_audiences(%Workspace{external_sharing_policy: "public"}), do: {0, nil}

  defp delete_workspace_in_transaction(_organization, _org_actor, actor, workspace) do
    with :ok <- Policy.authorize_workspace_change(actor),
         false <- workspace.is_default do
      workspace
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.no_assoc_constraint(:pastes)
      |> Repo.delete()
    else
      true -> {:error, :default_workspace_cannot_be_deleted}
      error -> error
    end
  end

  defp add_workspace_member_in_transaction(
         _organization,
         _org_actor,
         actor,
         workspace,
         user_id,
         role
       ) do
    with :ok <- Policy.authorize_workspace_change(actor),
         false <- workspace.is_default,
         %OrganizationMembership{} <-
           organization_membership_for(workspace.organization_id, user_id),
         {:ok, _user} <- lock_existing_user(user_id) do
      insert_workspace_membership(workspace.id, user_id, role, actor.user_id)
    else
      true -> {:error, :default_workspace_membership_required}
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp change_workspace_member_role_in_transaction(
         organization,
         _org_actor,
         actor,
         workspace,
         target,
         role
       ) do
    with %WorkspaceMembership{} = fresh <- workspace_membership(target),
         %OrganizationMembership{} <-
           organization_membership_for(workspace.organization_id, fresh.user_id),
         :ok <- Policy.authorize_workspace_change(actor),
         :ok <- preserve_personal_workspace_owner(organization, workspace, fresh, role),
         :ok <- preserve_workspace_owner(fresh, role) do
      fresh |> WorkspaceMembership.role_changeset(%{role: role}) |> Repo.update()
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp remove_workspace_in_transaction(
         organization,
         _org_actor,
         actor,
         workspace,
         target,
         leaving?
       ) do
    with %WorkspaceMembership{} = fresh <- workspace_membership(target, leaving?),
         %OrganizationMembership{} <-
           organization_membership_for(workspace.organization_id, fresh.user_id),
         :ok <- authorize_workspace_removal(actor, fresh, leaving?),
         false <- workspace.is_default,
         :ok <- preserve_personal_workspace_owner(organization, workspace, fresh, nil),
         :ok <- preserve_workspace_owner(fresh, nil) do
      Repo.delete(fresh)
    else
      true -> {:error, :default_workspace_membership_required}
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp organization_transaction(%Scope{user: %User{id: actor_id}}, organization_id, callback) do
    with {:ok, actor_id} <- public_id(actor_id),
         {:ok, organization_id} <- public_id(organization_id) do
      ensure_transaction_owner!()

      Repo.transact(fn -> run_organization_transaction(organization_id, actor_id, callback) end)
    end
  end

  defp organization_transaction(_, _, _), do: {:error, :not_found}

  defp workspace_transaction(
         %Scope{user: %User{id: actor_id}} = scope,
         %Workspace{id: workspace_id, organization_id: organization_id},
         callback
       ) do
    with {:ok, workspace_id} <- public_id(workspace_id),
         {:ok, organization_id} <- public_id(organization_id) do
      organization_transaction(
        scope,
        organization_id,
        &run_workspace_transaction(&1, &2, &3, workspace_id, actor_id, callback)
      )
    end
  end

  defp workspace_transaction(_, _, _), do: {:error, :not_found}

  defp run_organization_transaction(organization_id, actor_id, callback) do
    with %Organization{} = organization <-
           Repo.one(from o in Organization, where: o.id == ^organization_id, lock: "FOR UPDATE"),
         workspaces <-
           Repo.all(
             from w in Workspace,
               where: w.organization_id == ^organization_id,
               order_by: w.id,
               lock: "FOR UPDATE"
           ),
         %User{} <- lock_user(actor_id),
         %OrganizationMembership{} = actor <-
           Repo.get_by(OrganizationMembership,
             organization_id: organization_id,
             user_id: actor_id
           ) do
      callback.(organization, actor, workspaces)
    else
      nil -> {:error, :not_found}
    end
  end

  defp run_workspace_transaction(
         organization,
         org_actor,
         workspaces,
         workspace_id,
         actor_id,
         callback
       ) do
    with %Workspace{} = workspace <- Enum.find(workspaces, &(&1.id == workspace_id)),
         %WorkspaceMembership{} = actor <-
           Repo.get_by(WorkspaceMembership, workspace_id: workspace_id, user_id: actor_id) do
      callback.(organization, org_actor, actor, workspace)
    else
      nil -> {:error, :not_found}
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

  defp preserve_personal_owner(
         %Organization{personal_owner_id: user_id},
         %{user_id: user_id, role: role},
         new_role
       )
       when role != new_role,
       do: {:error, :personal_owner_required}

  defp preserve_personal_owner(_organization, _membership, _new_role), do: :ok

  defp preserve_personal_workspace_owner(
         %Organization{personal_owner_id: user_id},
         %Workspace{is_default: true},
         %{user_id: user_id, role: role},
         new_role
       )
       when role != new_role,
       do: {:error, :personal_owner_required}

  defp preserve_personal_workspace_owner(_organization, _workspace, _membership, _new_role),
    do: :ok

  defp organization_membership(m, composite_key? \\ false) do
    with {:ok, organization_id} <- public_id(m.organization_id),
         {:ok, user_id} <- public_id(m.user_id),
         {:ok, id_filter} <- membership_id_filter(m.id, composite_key?) do
      Repo.get_by(
        OrganizationMembership,
        [organization_id: organization_id, user_id: user_id] ++ id_filter
      )
    else
      _ -> nil
    end
  end

  defp workspace_membership(m, composite_key? \\ false) do
    with {:ok, workspace_id} <- public_id(m.workspace_id),
         {:ok, user_id} <- public_id(m.user_id),
         {:ok, id_filter} <- membership_id_filter(m.id, composite_key?) do
      Repo.get_by(
        WorkspaceMembership,
        [workspace_id: workspace_id, user_id: user_id] ++ id_filter
      )
    else
      _ -> nil
    end
  end

  defp workspace_for_membership(%{workspace_id: id}) do
    case public_id(id) do
      {:ok, id} -> Repo.get(Workspace, id)
      {:error, :not_found} -> nil
    end
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

  defp membership_id_filter(nil, true), do: {:ok, []}
  defp membership_id_filter(id, _), do: with({:ok, id} <- public_id(id), do: {:ok, [id: id]})

  defp create_with_default_workspace(changeset, creator) do
    Repo.transact(fn ->
      with {:ok, creator} <- lock_existing_user(creator.id) do
        create_with_default_workspace_in_transaction(changeset, creator)
      end
    end)
  end

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

  defp lock_user(id),
    do: Repo.one(from user in User, where: user.id == ^id, lock: "FOR KEY SHARE")

  defp lock_existing_user(id) do
    case lock_user(id) do
      %User{} = user -> {:ok, user}
      nil -> {:error, :not_found}
    end
  end

  defp ensure_transaction_owner! do
    if Repo.in_transaction?() do
      raise ArgumentError,
            "transaction-owning organization API cannot be called inside a Repo transaction"
    end
  end
end
