defmodule Textbin.Organizations do
  @moduledoc """
  Organization, workspace, and membership lifecycle boundaries.

  Membership mutations serialize on the organization and its workspaces so
  authorization and final-owner checks use current, locked state. Callers must
  use this context to keep default-workspace membership synchronized.
  """

  import Ecto.Query, warn: false

  alias Textbin.Accounts.{Scope, User}
  alias Textbin.Organizations.{AuditEvent, Organization, OrganizationMembership, Policy}
  alias Textbin.Organizations.{Workspace, WorkspaceMembership}
  alias Textbin.Pastes
  alias Textbin.Pastes.Paste
  alias Textbin.Repo

  @default_audit_page_size 50
  @max_audit_page_size 100

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
          where:
            w.id == ^id and is_nil(w.deletion_requested_at) and
              is_nil(o.deletion_requested_at),
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
        where:
          is_nil(workspace.deletion_requested_at) and
            is_nil(organization.deletion_requested_at),
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

  @doc "Resolves an organization membership by its stable URL slug without disclosing inaccessible records."
  def resolve_organization_scope_by_slug(
        %Scope{user: %User{id: user_id}} = scope,
        organization_slug
      )
      when is_binary(organization_slug) do
    query =
      from organization in Organization,
        join: membership in OrganizationMembership,
        on:
          membership.organization_id == organization.id and
            membership.user_id == ^user_id,
        where:
          organization.slug == ^organization_slug and
            is_nil(organization.deletion_requested_at),
        select: {organization, membership}

    case Repo.one(query) do
      {organization, membership} ->
        {:ok,
         %{
           scope
           | organization: organization,
             organization_membership: membership,
             workspace: nil,
             workspace_membership: nil
         }}

      nil ->
        {:error, :not_found}
    end
  end

  def resolve_organization_scope_by_slug(_, _), do: {:error, :not_found}

  def list_organization_members(%Scope{
        user: %User{id: user_id},
        organization: %Organization{id: organization_id}
      }) do
    with {:ok, user_id} <- public_id(user_id),
         {:ok, organization_id} <- public_id(organization_id) do
      organization_members_query(user_id, organization_id)
      |> order_by([membership, _actor, _organization, user], asc: user.email, asc: membership.id)
      |> Repo.all()
    else
      _error -> []
    end
  end

  def list_organization_members(_scope), do: []

  def get_organization_member(
        %Scope{
          user: %User{id: user_id},
          organization: %Organization{id: organization_id}
        },
        membership_id
      ) do
    with {:ok, user_id} <- public_id(user_id),
         {:ok, organization_id} <- public_id(organization_id),
         {:ok, membership_id} <- public_id(membership_id) do
      user_id
      |> organization_members_query(organization_id)
      |> where([membership], membership.id == ^membership_id)
      |> Repo.one()
    else
      _error -> nil
    end
  end

  def get_organization_member(_scope, _membership_id), do: nil

  def list_available_organizations(%Scope{user: %User{id: user_id}}) do
    Repo.all(
      from organization in Organization,
        join: membership in OrganizationMembership,
        on: membership.organization_id == organization.id,
        where: membership.user_id == ^user_id and is_nil(organization.deletion_requested_at),
        order_by: [asc: organization.name, asc: organization.id]
    )
  end

  def list_available_organizations(_scope), do: []

  def get_available_organization(%Scope{user: %User{id: user_id}}, id) do
    with {:ok, user_id} <- public_id(user_id),
         {:ok, organization_id} <- public_id(id) do
      Repo.one(
        from organization in Organization,
          join: membership in OrganizationMembership,
          on: membership.organization_id == organization.id and membership.user_id == ^user_id,
          where:
            organization.id == ^organization_id and is_nil(organization.deletion_requested_at)
      )
    else
      _error -> nil
    end
  end

  def get_available_organization(_scope, _id), do: nil

  def list_audit_events(%Scope{} = scope, %Organization{} = organization) do
    case list_audit_event_page(scope, organization, limit: @max_audit_page_size) do
      {:ok, %{events: events}} -> {:ok, events}
      error -> error
    end
  end

  def list_audit_events(_, _), do: {:error, :not_found}

  def list_audit_event_page(scope, organization, opts \\ [])

  def list_audit_event_page(
        %Scope{user: %User{id: actor_id}},
        %Organization{id: organization_id},
        opts
      ) do
    with {:ok, actor_id} <- public_id(actor_id),
         {:ok, organization_id} <- public_id(organization_id) do
      ensure_transaction_owner!()
      limit = audit_page_limit(Keyword.get(opts, :limit))
      cursor = Keyword.get(opts, :cursor)

      Repo.transact(fn ->
        list_audit_event_page_in_transaction(actor_id, organization_id, limit, cursor)
      end)
    end
  end

  def list_audit_event_page(_, _, _), do: {:error, :not_found}

  defp list_audit_event_page_in_transaction(actor_id, organization_id, limit, cursor) do
    with %Organization{} <-
           Repo.one(
             from organization in Organization,
               where:
                 organization.id == ^organization_id and
                   is_nil(organization.deletion_requested_at),
               lock: "FOR SHARE"
           ),
         %OrganizationMembership{} = actor <-
           Repo.get_by(OrganizationMembership,
             organization_id: organization_id,
             user_id: actor_id
           ),
         true <- Policy.organization_owner?(actor),
         {:ok, query} <- audit_event_page_query(organization_id, cursor) do
      events = Repo.all(from event in query, limit: ^(limit + 1))
      page_events = Enum.take(events, limit)

      {:ok,
       %{
         events: page_events,
         next_cursor: if(length(events) > limit, do: List.last(page_events).id)
       }}
    else
      false -> {:error, :unauthorized}
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp audit_event_page_query(organization_id, nil) do
    query =
      from event in AuditEvent,
        where: event.organization_id == ^organization_id,
        order_by: [desc: event.inserted_at, desc: event.id]

    {:ok, query}
  end

  defp audit_event_page_query(organization_id, cursor) do
    with {:ok, cursor_id} <- public_id(cursor),
         %AuditEvent{} = cursor_event <-
           Repo.get_by(AuditEvent, id: cursor_id, organization_id: organization_id) do
      query =
        from event in AuditEvent,
          where:
            event.organization_id == ^organization_id and
              (event.inserted_at < ^cursor_event.inserted_at or
                 (event.inserted_at == ^cursor_event.inserted_at and event.id < ^cursor_event.id)),
          order_by: [desc: event.inserted_at, desc: event.id]

      {:ok, query}
    else
      _error -> {:error, :not_found}
    end
  end

  defp audit_page_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {limit, ""} -> audit_page_limit(limit)
      _error -> @default_audit_page_size
    end
  end

  defp audit_page_limit(limit) when is_integer(limit),
    do: limit |> max(1) |> min(@max_audit_page_size)

  defp audit_page_limit(_limit), do: @default_audit_page_size

  def list_joined_workspaces(
        %Scope{user: %User{id: user_id}},
        %Organization{id: organization_id}
      ) do
    Repo.all(
      from workspace in Workspace,
        join: membership in WorkspaceMembership,
        on: membership.workspace_id == workspace.id,
        where:
          workspace.organization_id == ^organization_id and membership.user_id == ^user_id and
            is_nil(workspace.deletion_requested_at),
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
             ),
           :ok <-
             record_audit(
               fresh_organization.id,
               actor.user_id,
               "workspace.created",
               "workspace",
               workspace.id,
               %{"visibility" => workspace.visibility}
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
                is_nil(workspace.deletion_requested_at) and
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
    with {:ok, deletion_workspace} <-
           workspace_transaction(
             scope,
             workspace,
             &request_workspace_deletion_in_transaction/4,
             true
           ),
         :ok <- Pastes.delete_workspace_pastes(deletion_workspace.id) do
      workspace_transaction(scope, deletion_workspace, &delete_workspace_in_transaction/4, true)
    end
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
           :ok <- preserve_organization_owner(fresh, role),
           old_role = fresh.role,
           {:ok, membership} <-
             fresh |> OrganizationMembership.role_changeset(%{role: role}) |> Repo.update(),
           :ok <-
             record_role_change_audit(
               organization.id,
               actor.user_id,
               "organization.membership.role_changed",
               fresh.user_id,
               old_role,
               role,
               %{}
             ) do
        {:ok, membership}
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

  def recover_workspace_access(
        %Scope{user: %User{id: user_id}} = scope,
        %Workspace{id: workspace_id, organization_id: organization_id}
      ) do
    organization_transaction(scope, organization_id, fn organization, actor, workspaces ->
      with true <- Policy.organization_owner?(actor),
           %Workspace{visibility: "private", deletion_requested_at: nil} = workspace <-
             Enum.find(workspaces, &(&1.id == workspace_id)),
           {:ok, membership} <- recover_workspace_membership(workspace.id, user_id),
           :ok <-
             record_audit(
               organization.id,
               user_id,
               "workspace.recovery_access_granted",
               "workspace",
               workspace.id,
               %{"role" => Policy.workspace_owner_role()}
             ) do
        {:ok, membership}
      else
        false -> {:error, :unauthorized}
        nil -> {:error, :not_found}
        error -> error
      end
    end)
  end

  def recover_workspace_access(%Scope{} = scope, workspace_id) when is_binary(workspace_id) do
    with {:ok, workspace_id} <- public_id(workspace_id),
         %Workspace{} = workspace <- Repo.get(Workspace, workspace_id) do
      recover_workspace_access(scope, workspace)
    else
      _error -> {:error, :not_found}
    end
  end

  def recover_workspace_access(_, _), do: {:error, :not_found}

  def delete_account(%Scope{user: %User{id: user_id}}) do
    ensure_transaction_owner!()

    with {:ok, personal_workspace_ids} <-
           Repo.transact(fn -> prepare_account_deletion(user_id) end),
         :ok <- delete_workspace_pastes(personal_workspace_ids) do
      Repo.transact(fn -> finalize_account_deletion(user_id) end)
    end
  end

  def delete_account(_scope), do: {:error, :not_found}

  defp remove_organization(scope, target, leaving?) do
    organization_transaction(scope, target.organization_id, fn organization, actor, workspaces ->
      with %OrganizationMembership{} = fresh <- organization_membership(target, leaving?),
           :ok <- authorize_org_removal(actor, fresh, leaving?),
           :ok <- preserve_personal_owner(organization, fresh, nil),
           :ok <- preserve_organization_owner(fresh, nil),
           :ok <- preserve_owned_workspaces(fresh.user_id, workspaces) do
        delete_organization_membership(organization, actor, fresh, workspaces, leaving?)
      else
        nil -> {:error, :not_found}
        error -> error
      end
    end)
  end

  defp organization_members_query(user_id, organization_id) do
    from membership in OrganizationMembership,
      join: actor in OrganizationMembership,
      on:
        actor.organization_id == membership.organization_id and
          actor.user_id == ^user_id,
      join: organization in Organization,
      on: organization.id == membership.organization_id,
      join: user in assoc(membership, :user),
      where:
        membership.organization_id == ^organization_id and
          is_nil(organization.deletion_requested_at),
      preload: [user: user]
  end

  defp delete_organization_membership(organization, actor, membership, workspaces, leaving?) do
    Repo.delete_all(
      from workspace_membership in WorkspaceMembership,
        where:
          workspace_membership.user_id == ^membership.user_id and
            workspace_membership.workspace_id in ^Enum.map(workspaces, & &1.id)
    )

    with {:ok, membership} <- Repo.delete(membership),
         :ok <-
           record_audit(
             organization.id,
             actor.user_id,
             "organization.membership.removed",
             "user",
             membership.user_id,
             %{"role" => membership.role, "self" => leaving?}
           ) do
      {:ok, membership}
    end
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
           ),
         :ok <-
           record_audit(
             organization_id,
             actor.user_id,
             "organization.membership.added",
             "user",
             user_id,
             %{"role" => role}
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
         :ok <- Policy.authorize_workspace_join(workspace),
         {:ok, membership} <-
           insert_workspace_membership(
             workspace.id,
             user_id,
             Policy.workspace_member_role(),
             actor.user_id
           ),
         :ok <-
           record_audit(
             workspace.organization_id,
             actor.user_id,
             "workspace.membership.added",
             "user",
             user_id,
             %{"role" => membership.role, "workspace_id" => workspace.id}
           ) do
      {:ok, membership}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp change_workspace_settings_in_transaction(
         organization,
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

      with :ok <-
             record_workspace_setting_audits(
               organization.id,
               actor.user_id,
               workspace,
               updated_workspace
             ) do
        {:ok, updated_workspace}
      end
    end
  end

  defp clamp_paste_audiences(%Workspace{id: workspace_id, external_sharing_policy: "disabled"}) do
    updated_at = Paste.utc_now_ms()

    Repo.update_all(
      from(paste in Paste,
        where: paste.workspace_id == ^workspace_id and paste.audience != "workspace"
      ),
      set: [audience: "workspace", updated_at: updated_at]
    )
  end

  defp clamp_paste_audiences(%Workspace{id: workspace_id, external_sharing_policy: "unlisted"}) do
    updated_at = Paste.utc_now_ms()

    Repo.update_all(
      from(paste in Paste,
        where: paste.workspace_id == ^workspace_id and paste.audience == "public"
      ),
      set: [audience: "unlisted", updated_at: updated_at]
    )
  end

  defp clamp_paste_audiences(%Workspace{external_sharing_policy: "public"}), do: {0, nil}

  defp request_workspace_deletion_in_transaction(
         _organization,
         _org_actor,
         actor,
         workspace
       ) do
    with :ok <- Policy.authorize_workspace_change(actor),
         false <- workspace.is_default do
      requested_at = workspace.deletion_requested_at || Paste.utc_now_ms()

      Repo.update_all(
        from(paste in Paste,
          where: paste.workspace_id == ^workspace.id
        ),
        set: [expires_at: requested_at, updated_at: requested_at]
      )

      workspace
      |> Ecto.Changeset.change(deletion_requested_at: requested_at)
      |> Repo.update()
    else
      true -> {:error, :default_workspace_cannot_be_deleted}
      error -> error
    end
  end

  defp delete_workspace_in_transaction(organization, _org_actor, actor, workspace) do
    with :ok <- Policy.authorize_workspace_change(actor),
         false <- workspace.is_default,
         {:ok, deleted_workspace} <-
           workspace
           |> Ecto.Changeset.change()
           |> Ecto.Changeset.no_assoc_constraint(:pastes)
           |> Repo.delete(),
         :ok <-
           record_audit(
             organization.id,
             actor.user_id,
             "workspace.deleted",
             "workspace",
             workspace.id,
             %{"name" => workspace.name}
           ) do
      {:ok, deleted_workspace}
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
      with {:ok, membership} <-
             insert_workspace_membership(workspace.id, user_id, role, actor.user_id),
           :ok <-
             record_audit(
               workspace.organization_id,
               actor.user_id,
               "workspace.membership.added",
               "user",
               user_id,
               %{"role" => role, "workspace_id" => workspace.id}
             ) do
        {:ok, membership}
      end
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
         :ok <- preserve_workspace_owner(fresh, role),
         old_role = fresh.role,
         {:ok, membership} <-
           fresh |> WorkspaceMembership.role_changeset(%{role: role}) |> Repo.update(),
         :ok <-
           record_role_change_audit(
             organization.id,
             actor.user_id,
             "workspace.membership.role_changed",
             fresh.user_id,
             old_role,
             role,
             %{"workspace_id" => workspace.id}
           ) do
      {:ok, membership}
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
         :ok <- preserve_workspace_owner(fresh, nil),
         {:ok, membership} <- Repo.delete(fresh),
         :ok <-
           record_audit(
             organization.id,
             actor.user_id,
             "workspace.membership.removed",
             "user",
             fresh.user_id,
             %{"role" => fresh.role, "workspace_id" => workspace.id, "self" => leaving?}
           ) do
      {:ok, membership}
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

  defp workspace_transaction(scope, workspace, callback, allow_deleting? \\ false)

  defp workspace_transaction(
         %Scope{user: %User{id: actor_id}} = scope,
         %Workspace{id: workspace_id, organization_id: organization_id},
         callback,
         allow_deleting?
       ) do
    with {:ok, workspace_id} <- public_id(workspace_id),
         {:ok, organization_id} <- public_id(organization_id) do
      organization_transaction(
        scope,
        organization_id,
        &run_workspace_transaction(
          &1,
          &2,
          &3,
          workspace_id,
          actor_id,
          callback,
          allow_deleting?
        )
      )
    end
  end

  defp workspace_transaction(_, _, _, _), do: {:error, :not_found}

  defp run_organization_transaction(organization_id, actor_id, callback) do
    with %Organization{} = organization <-
           Repo.one(
             from o in Organization,
               where: o.id == ^organization_id and is_nil(o.deletion_requested_at),
               lock: "FOR UPDATE"
           ),
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
         callback,
         allow_deleting?
       ) do
    with %Workspace{} = workspace <- Enum.find(workspaces, &(&1.id == workspace_id)),
         true <- allow_deleting? or is_nil(workspace.deletion_requested_at),
         %WorkspaceMembership{} = actor <-
           Repo.get_by(WorkspaceMembership, workspace_id: workspace_id, user_id: actor_id) do
      callback.(organization, org_actor, actor, workspace)
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
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
         :ok <-
           record_audit(
             organization.id,
             creator.id,
             "workspace.created",
             "workspace",
             workspace.id,
             %{"visibility" => workspace.visibility, "default" => true}
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

  defp recover_workspace_membership(workspace_id, user_id) do
    case Repo.get_by(WorkspaceMembership, workspace_id: workspace_id, user_id: user_id) do
      nil ->
        insert_workspace_membership(
          workspace_id,
          user_id,
          Policy.workspace_owner_role(),
          user_id
        )

      %WorkspaceMembership{} = membership ->
        membership
        |> WorkspaceMembership.role_changeset(%{role: Policy.workspace_owner_role()})
        |> Repo.update()
    end
  end

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

  defp record_audit(organization_id, actor_user_id, action, target_type, target_id, metadata) do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      organization_id: organization_id,
      actor_user_id: actor_user_id,
      action: action,
      target_type: target_type,
      target_id: target_id,
      metadata: metadata
    })
    |> Repo.insert()
    |> case do
      {:ok, _event} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp record_role_change_audit(
         _organization_id,
         _actor_user_id,
         _action,
         _target_id,
         role,
         role,
         _metadata
       ),
       do: :ok

  defp record_role_change_audit(
         organization_id,
         actor_user_id,
         action,
         target_id,
         old_role,
         new_role,
         metadata
       ) do
    record_audit(
      organization_id,
      actor_user_id,
      action,
      "user",
      target_id,
      Map.merge(metadata, %{"old_role" => old_role, "new_role" => new_role})
    )
  end

  defp record_workspace_setting_audits(organization_id, actor_user_id, previous, updated) do
    [
      {:visibility, "workspace.visibility_changed"},
      {:external_sharing_policy, "workspace.external_sharing_policy_changed"}
    ]
    |> Enum.reduce_while(:ok, fn {field, action}, :ok ->
      case record_workspace_setting_audit(
             organization_id,
             actor_user_id,
             previous,
             updated,
             field,
             action
           ) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp record_workspace_setting_audit(
         organization_id,
         actor_user_id,
         previous,
         updated,
         field,
         action
       ) do
    old_value = Map.fetch!(previous, field)
    new_value = Map.fetch!(updated, field)

    if old_value == new_value do
      :ok
    else
      record_audit(
        organization_id,
        actor_user_id,
        action,
        "workspace",
        updated.id,
        %{"old" => old_value, "new" => new_value}
      )
    end
  end

  defp prepare_account_deletion(user_id) do
    with {:ok, user, organizations, workspaces} <- lock_account_state(user_id),
         :ok <- require_transferred_team_ownership(user.id, organizations, workspaces),
         personal_workspace_ids when personal_workspace_ids != [] <-
           personal_workspace_ids(organizations, workspaces) do
      requested_at = Paste.utc_now_ms()
      personal_organization_ids = personal_organization_ids(organizations)

      Repo.update_all(
        from(paste in Paste,
          where: paste.workspace_id in ^personal_workspace_ids
        ),
        set: [expires_at: requested_at, updated_at: requested_at]
      )

      Repo.update_all(
        from(workspace in Workspace,
          where:
            workspace.id in ^personal_workspace_ids and is_nil(workspace.deletion_requested_at)
        ),
        set: [deletion_requested_at: requested_at, updated_at: requested_at]
      )

      Repo.update_all(
        from(organization in Organization,
          where: organization.id in ^personal_organization_ids
        ),
        set: [deletion_requested_at: requested_at, updated_at: requested_at]
      )

      {:ok, personal_workspace_ids}
    else
      [] -> {:error, :not_found}
      error -> error
    end
  end

  defp personal_workspace_ids(organizations, workspaces) do
    personal_organization_ids = personal_organization_ids(organizations)

    for workspace <- workspaces,
        workspace.organization_id in personal_organization_ids,
        do: workspace.id
  end

  defp personal_organization_ids(organizations),
    do: for(organization <- organizations, organization.kind == "personal", do: organization.id)

  defp delete_workspace_pastes(workspace_ids) do
    Enum.reduce_while(workspace_ids, :ok, fn workspace_id, :ok ->
      case Pastes.delete_workspace_pastes(workspace_id) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp finalize_account_deletion(user_id) do
    with {:ok, user, organizations, workspaces} <- lock_account_state(user_id),
         :ok <- require_transferred_team_ownership(user.id, organizations, workspaces),
         :ok <- record_account_deletion_audits(user, organizations) do
      Repo.delete(user)
    end
  end

  defp record_account_deletion_audits(user, organizations) do
    organizations
    |> Enum.reject(&(&1.kind == "personal"))
    |> Enum.reduce_while(:ok, fn organization, :ok ->
      case record_audit(
             organization.id,
             user.id,
             "organization.membership.removed",
             "user",
             user.id,
             %{"reason" => "account_deleted"}
           ) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp lock_account_state(user_id) do
    organization_ids =
      Repo.all(
        from membership in OrganizationMembership,
          where: membership.user_id == ^user_id,
          select: membership.organization_id
      )

    organizations =
      Repo.all(
        from organization in Organization,
          where: organization.id in ^organization_ids,
          order_by: organization.id,
          lock: "FOR UPDATE"
      )

    workspaces =
      Repo.all(
        from workspace in Workspace,
          where: workspace.organization_id in ^organization_ids,
          order_by: workspace.id,
          lock: "FOR UPDATE"
      )

    case lock_user(user_id) do
      %User{} = user -> {:ok, user, organizations, workspaces}
      nil -> {:error, :not_found}
    end
  end

  defp require_transferred_team_ownership(user_id, organizations, workspaces) do
    team_ids = for organization <- organizations, organization.kind == "team", do: organization.id

    workspace_ids =
      for workspace <- workspaces, workspace.organization_id in team_ids, do: workspace.id

    final_organization_owner? = final_organization_owner?(user_id, team_ids)
    final_workspace_owner? = final_workspace_owner?(user_id, workspace_ids)

    if final_organization_owner? or final_workspace_owner?,
      do: {:error, :ownership_transfer_required},
      else: :ok
  end

  defp final_organization_owner?(user_id, organization_ids) do
    Repo.exists?(
      from membership in OrganizationMembership,
        left_join: other_owner in OrganizationMembership,
        on:
          other_owner.organization_id == membership.organization_id and
            other_owner.role == "owner" and other_owner.user_id != ^user_id,
        where:
          membership.user_id == ^user_id and membership.organization_id in ^organization_ids and
            membership.role == "owner" and is_nil(other_owner.id)
    )
  end

  defp final_workspace_owner?(user_id, workspace_ids) do
    Repo.exists?(
      from membership in WorkspaceMembership,
        left_join: other_owner in WorkspaceMembership,
        on:
          other_owner.workspace_id == membership.workspace_id and other_owner.role == "owner" and
            other_owner.user_id != ^user_id,
        where:
          membership.user_id == ^user_id and membership.workspace_id in ^workspace_ids and
            membership.role == "owner" and is_nil(other_owner.id)
    )
  end

  defp ensure_transaction_owner! do
    if Repo.in_transaction?() do
      raise ArgumentError,
            "transaction-owning organization API cannot be called inside a Repo transaction"
    end
  end
end
