defmodule Textbin.Administration do
  @moduledoc """
  Installation-wide authorization and audited platform authority changes.

  Caller identity comes from `Scope`, but every operation reloads authority from
  the database. Privilege and suspension changes share one transaction lock so
  concurrent operations cannot remove the final active administrator.
  """

  import Ecto.Query, warn: false

  alias Textbin.Accounts
  alias Textbin.Accounts.{Scope, User, UserToken}
  alias Textbin.Administration.PlatformAuditEvent

  alias Textbin.Organizations.{
    Organization,
    OrganizationMembership,
    Workspace,
    WorkspaceMembership
  }

  alias Textbin.Pastes.Paste
  alias Textbin.Repo

  @platform_admin_role "admin"
  @authority_lock_key 8_174_021_483_001
  @default_page_size 25
  @max_page_size 100

  @doc "Returns the current user when the scope has active platform authority."
  def authorize_platform_admin(%Scope{user: %User{id: user_id}}) do
    case Repo.get(User, user_id) do
      %User{} = user -> authorize_active_admin(user)
      nil -> {:error, :forbidden}
    end
  end

  def authorize_platform_admin(_scope), do: {:error, :forbidden}

  @doc "Returns bounded installation totals for the administration overview."
  def get_installation_overview(scope) do
    with {:ok, _admin} <- authorize_platform_admin(scope) do
      now = Paste.utc_now_ms()

      {:ok,
       %{
         registered_users: Repo.aggregate(from(u in User, where: u.kind == "registered"), :count),
         suspended_users:
           Repo.aggregate(from(u in User, where: not is_nil(u.suspended_at)), :count),
         organizations: Repo.aggregate(Organization, :count),
         workspaces: Repo.aggregate(Workspace, :count),
         active_pastes:
           Repo.aggregate(
             from(p in Paste, where: is_nil(p.expires_at) or p.expires_at > ^now),
             :count
           ),
         active_paste_bytes:
           Repo.one(
             from p in Paste,
               where: is_nil(p.expires_at) or p.expires_at > ^now,
               select:
                 fragment(
                   "COALESCE(SUM(COALESCE(?, octet_length(?), 0)), 0)::bigint",
                   p.size_bytes,
                   p.data
                 )
           )
       }}
    end
  end

  @doc "Looks up exact user, organization, and workspace identifiers without broad search."
  def lookup(scope, term) when is_binary(term) do
    with {:ok, _admin} <- authorize_platform_admin(scope) do
      term = String.trim(term)

      {:ok,
       %{
         user: lookup_user(term),
         organization: lookup_organization(term),
         workspace: lookup_workspace(term)
       }}
    end
  end

  def lookup(scope, _term) do
    with {:ok, _admin} <- authorize_platform_admin(scope) do
      {:ok, %{user: nil, organization: nil, workspace: nil}}
    end
  end

  @doc "Lists active public paste metadata newest first without loading paste bodies."
  def list_recent_public_pastes(scope, opts \\ []) do
    with {:ok, _admin} <- authorize_platform_admin(scope) do
      limit = page_limit(Keyword.get(opts, :limit))
      offset = page_offset(Keyword.get(opts, :page), limit)
      now = Paste.utc_now_ms()

      query =
        from paste in Paste,
          join: workspace in Workspace,
          on: workspace.id == paste.workspace_id,
          join: organization in Organization,
          on: organization.id == workspace.organization_id,
          where:
            paste.audience == "public" and workspace.external_sharing_policy == "public" and
              is_nil(workspace.deletion_requested_at) and
              is_nil(organization.deletion_requested_at) and
              (is_nil(paste.expires_at) or paste.expires_at > ^now),
          order_by: [desc: paste.inserted_at, desc: paste.id],
          limit: ^(limit + 1),
          offset: ^offset,
          select: %{
            id: paste.id,
            size_bytes: paste.size_bytes,
            content_type: paste.content_type,
            syntax_highlight: paste.syntax_highlight,
            audience: paste.audience,
            expires_at: paste.expires_at,
            inserted_at: paste.inserted_at,
            organization_name: organization.name,
            workspace_name: workspace.name
          }

      {:ok, page(Repo.all(query), limit, Keyword.get(opts, :page))}
    end
  end

  @doc "Lists largest active paste metadata without exposing non-public capability IDs."
  def list_largest_pastes(scope, opts \\ []) do
    with {:ok, _admin} <- authorize_platform_admin(scope) do
      limit = page_limit(Keyword.get(opts, :limit))
      offset = page_offset(Keyword.get(opts, :page), limit)
      now = Paste.utc_now_ms()

      query =
        from paste in Paste,
          join: workspace in Workspace,
          on: workspace.id == paste.workspace_id,
          join: organization in Organization,
          on: organization.id == workspace.organization_id,
          where:
            is_nil(workspace.deletion_requested_at) and
              is_nil(organization.deletion_requested_at) and
              (is_nil(paste.expires_at) or paste.expires_at > ^now),
          order_by: [
            desc_nulls_last: paste.size_bytes,
            desc: paste.inserted_at,
            desc: paste.id
          ],
          limit: ^(limit + 1),
          offset: ^offset,
          select: %{
            id:
              type(
                fragment(
                  "CASE WHEN ? = 'public' AND ? = 'public' THEN ? ELSE NULL END",
                  paste.audience,
                  workspace.external_sharing_policy,
                  paste.id
                ),
                :binary_id
              ),
            size_bytes:
              fragment(
                "COALESCE(?, octet_length(?), 0)::bigint",
                paste.size_bytes,
                paste.data
              ),
            content_type: paste.content_type,
            syntax_highlight: paste.syntax_highlight,
            audience: paste.audience,
            expires_at: paste.expires_at,
            inserted_at: paste.inserted_at,
            organization_name: organization.name,
            workspace_name: workspace.name
          }

      {:ok, page(Repo.all(query), limit, Keyword.get(opts, :page))}
    end
  end

  @doc "Lists the append-only platform audit log newest first."
  def list_platform_audit_events(scope, opts \\ []) do
    with {:ok, _admin} <- authorize_platform_admin(scope) do
      limit = page_limit(Keyword.get(opts, :limit))

      with {:ok, query} <- platform_audit_event_query(Keyword.get(opts, :cursor)) do
        events = Repo.all(from event in query, limit: ^(limit + 1))
        entries = Enum.take(events, limit)

        {:ok,
         %{
           entries: entries,
           next_cursor: if(length(events) > limit, do: List.last(entries).id)
         }}
      end
    end
  end

  @doc false
  def authorize_account_deletion(%Scope{user: %User{id: user_id}} = scope) do
    case Repo.transact(fn -> authorize_account_deletion_in_transaction(scope, user_id) end) do
      {:ok, :authorized} -> :ok
      error -> error
    end
  end

  def authorize_account_deletion(_scope), do: {:error, :not_found}

  @doc false
  def lock_platform_authority_changes, do: lock_authority_changes()

  @doc false
  def record_platform_account_deletion(%User{platform_role: nil}, _authenticated_at), do: :ok

  def record_platform_account_deletion(%User{} = user, authenticated_at) do
    if Repo.in_transaction?() do
      scope = Scope.for_user(%{user | authenticated_at: authenticated_at})

      with :ok <- require_recent_reauthentication(scope),
           :ok <- preserve_active_admin(user.id, user.platform_role) do
        record_user_audit(
          user,
          "platform.admin.account_deleted",
          user,
          "account_deleted",
          %{"previous_role" => user.platform_role},
          []
        )
      end
    else
      raise "platform account deletion audit requires a database transaction"
    end
  end

  @doc "Bootstraps or recovers platform authority through an audited release RPC."
  def bootstrap_platform_admin(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()
    Repo.transact(fn -> bootstrap_platform_admin_in_transaction(email) end)
  end

  @doc "Grants platform authority to an eligible user."
  def grant_platform_admin(scope, target, reason, opts \\ []) do
    with {:ok, reason} <- normalize_reason(reason),
         {:ok, target_id} <- user_id(target) do
      authority_transaction(
        scope,
        &grant_platform_admin_in_transaction(&1, target_id, reason, opts)
      )
    end
  end

  @doc "Revokes platform authority while preserving one active administrator."
  def revoke_platform_admin(scope, target, reason, opts \\ []) do
    result =
      with {:ok, reason} <- normalize_reason(reason),
           {:ok, target_id} <- user_id(target) do
        authority_transaction(
          scope,
          &revoke_platform_admin_in_transaction(&1, target_id, reason, opts)
        )
      end

    notify_platform_authority_change(result)
  end

  @doc "Grants a replacement and revokes an administrator in one transaction."
  def transfer_platform_admin(scope, target, replacement, reason, opts \\ []) do
    result =
      with {:ok, reason} <- normalize_reason(reason),
           {:ok, target_id} <- user_id(target),
           {:ok, replacement_id} <- user_id(replacement),
           :ok <- distinct_users(target_id, replacement_id) do
        authority_transaction(
          scope,
          &transfer_platform_admin_in_transaction(
            &1,
            target_id,
            replacement_id,
            reason,
            opts
          )
        )
      end

    notify_platform_authority_change(result)
  end

  @doc "Subscribes the current user to changes in their platform authority."
  def subscribe_to_platform_authority(scope) do
    with {:ok, %User{id: user_id}} <- authorize_platform_admin(scope) do
      Phoenix.PubSub.subscribe(Textbin.PubSub, platform_authority_topic(user_id))
    end
  end

  @doc "Suspends an account and revokes all of its authentication tokens."
  def suspend_user(scope, target, reason, opts \\ []) do
    result =
      with {:ok, reason} <- normalize_reason(reason),
           {:ok, target_id} <- user_id(target),
           :ok <- not_self(scope, target_id) do
        authority_transaction(
          scope,
          &suspend_user_in_transaction(&1, target_id, reason, opts)
        )
      end

    disconnect_suspended_sessions(result)
  end

  @doc "Restores a suspended account without restoring its revoked tokens."
  def restore_user(scope, target, reason, opts \\ []) do
    with {:ok, reason} <- normalize_reason(reason),
         {:ok, target_id} <- user_id(target) do
      authority_transaction(scope, &restore_user_in_transaction(&1, target_id, reason, opts))
    end
  end

  defp authorize_account_deletion_in_transaction(scope, user_id) do
    with :ok <- lock_authority_changes(),
         %User{suspended_at: nil} = user <- lock_user(user_id),
         :ok <- require_account_deletion_reauthentication(scope, user),
         :ok <- preserve_active_admin(user.id, user.platform_role) do
      {:ok, :authorized}
    else
      nil -> {:error, :not_found}
      %User{} -> {:error, :not_found}
      error -> error
    end
  end

  defp bootstrap_platform_admin_in_transaction(email) do
    with :ok <- lock_authority_changes(),
         %User{} = user <- lock_user_by_email(email),
         :ok <- eligible_admin_target(user) do
      grant_bootstrap_role(user)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp grant_bootstrap_role(user) do
    result = if user.platform_role == @platform_admin_role, do: :already_present, else: :granted

    with {:ok, user} <- put_platform_role(user, @platform_admin_role),
         :ok <- record_bootstrap_audit(user, result) do
      {:ok, result}
    end
  end

  defp grant_platform_admin_in_transaction(actor, target_id, reason, opts) do
    with %User{} = target <- lock_user(target_id),
         :ok <- eligible_admin_target(target) do
      grant_platform_role(actor, target, reason, opts)
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp grant_platform_role(_actor, %User{platform_role: @platform_admin_role}, _reason, _opts),
    do: {:ok, :already_present}

  defp grant_platform_role(actor, target, reason, opts) do
    with {:ok, target} <- put_platform_role(target, @platform_admin_role),
         :ok <-
           record_user_audit(
             actor,
             "platform.admin.granted",
             target,
             reason,
             %{"previous_role" => nil, "new_role" => @platform_admin_role},
             opts
           ) do
      {:ok, target}
    end
  end

  defp revoke_platform_admin_in_transaction(actor, target_id, reason, opts) do
    with %User{platform_role: @platform_admin_role} = target <- lock_user(target_id),
         :ok <- preserve_active_admin(target.id, target.platform_role),
         {:ok, target} <- put_platform_role(target, nil),
         :ok <-
           record_user_audit(
             actor,
             "platform.admin.revoked",
             target,
             reason,
             %{"previous_role" => @platform_admin_role, "new_role" => nil},
             opts
           ) do
      {:ok, target}
    else
      nil -> {:error, :not_found}
      %User{} -> {:error, :not_found}
      error -> error
    end
  end

  defp transfer_platform_admin_in_transaction(actor, target_id, replacement_id, reason, opts) do
    with %User{platform_role: @platform_admin_role} = target <- lock_user(target_id),
         %User{} = replacement <- lock_user(replacement_id),
         :ok <- eligible_admin_target(replacement),
         {:ok, replacement} <- maybe_grant_replacement(actor, replacement, reason, opts),
         {:ok, target} <- put_platform_role(target, nil),
         :ok <- record_transfer_revocation(actor, target, replacement, reason, opts) do
      {:ok, %{revoked: target, replacement: replacement}}
    else
      nil -> {:error, :not_found}
      %User{} -> {:error, :not_found}
      error -> error
    end
  end

  defp record_transfer_revocation(actor, target, replacement, reason, opts) do
    record_user_audit(
      actor,
      "platform.admin.revoked",
      target,
      reason,
      %{
        "previous_role" => @platform_admin_role,
        "new_role" => nil,
        "replacement_user_id" => replacement.id
      },
      opts
    )
  end

  defp suspend_user_in_transaction(actor, target_id, reason, opts) do
    with %User{} = target <- lock_user(target_id),
         :ok <- not_suspended(target),
         :ok <- preserve_active_admin(target.id, target.platform_role),
         tokens <- Repo.all_by(UserToken, user_id: target.id),
         {:ok, target} <- suspend_account(target),
         {_count, nil} <-
           Repo.delete_all(from token in UserToken, where: token.user_id == ^target.id),
         :ok <-
           record_user_audit(
             actor,
             "platform.account.suspended",
             target,
             reason,
             %{},
             opts
           ) do
      {:ok, {target, tokens}}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp suspend_account(target) do
    target
    |> Ecto.Changeset.change(suspended_at: DateTime.utc_now(:second))
    |> Repo.update()
  end

  defp restore_user_in_transaction(actor, target_id, reason, opts) do
    with %User{suspended_at: %DateTime{}} = target <- lock_user(target_id),
         {:ok, target} <-
           target
           |> Ecto.Changeset.change(suspended_at: nil)
           |> Repo.update(),
         :ok <-
           record_user_audit(
             actor,
             "platform.account.restored",
             target,
             reason,
             %{},
             opts
           ) do
      {:ok, target}
    else
      nil -> {:error, :not_found}
      %User{} -> {:error, :not_found}
      error -> error
    end
  end

  defp authority_transaction(%Scope{} = scope, callback) do
    Repo.transact(fn ->
      with :ok <- lock_authority_changes(),
           {:ok, actor} <- lock_platform_admin(scope),
           :ok <- require_recent_reauthentication(scope) do
        callback.(actor)
      end
    end)
  end

  defp authority_transaction(_scope, _callback), do: {:error, :forbidden}

  defp lock_platform_admin(%Scope{user: %User{id: user_id}}) do
    case lock_user(user_id) do
      %User{} = user -> authorize_active_admin(user)
      nil -> {:error, :forbidden}
    end
  end

  defp authorize_active_admin(
         %User{
           platform_role: @platform_admin_role,
           confirmed_at: %DateTime{},
           suspended_at: nil
         } = user
       ),
       do: {:ok, user}

  defp authorize_active_admin(_user), do: {:error, :forbidden}

  defp require_recent_reauthentication(%Scope{user: %User{} = user}) do
    if Accounts.sudo_mode?(user), do: :ok, else: {:error, :reauthentication_required}
  end

  defp require_account_deletion_reauthentication(_scope, %User{platform_role: nil}), do: :ok

  defp require_account_deletion_reauthentication(scope, %User{}),
    do: require_recent_reauthentication(scope)

  defp eligible_admin_target(%User{
         kind: "registered",
         confirmed_at: %DateTime{},
         suspended_at: nil
       }),
       do: :ok

  defp eligible_admin_target(%User{kind: kind}) when kind != "registered",
    do: {:error, :ineligible}

  defp eligible_admin_target(%User{confirmed_at: nil}), do: {:error, :unconfirmed}
  defp eligible_admin_target(%User{suspended_at: %DateTime{}}), do: {:error, :suspended}
  defp eligible_admin_target(_user), do: {:error, :ineligible}

  defp preserve_active_admin(target_id, @platform_admin_role) do
    active_admins =
      Repo.aggregate(
        from(user in User,
          where:
            user.platform_role == @platform_admin_role and not is_nil(user.confirmed_at) and
              is_nil(user.suspended_at) and user.id != ^target_id
        ),
        :count
      )

    if active_admins > 0, do: :ok, else: {:error, :final_active_admin}
  end

  defp preserve_active_admin(_target_id, _role), do: :ok

  defp maybe_grant_replacement(
         _actor,
         %User{platform_role: @platform_admin_role} = user,
         _reason,
         _opts
       ),
       do: {:ok, user}

  defp maybe_grant_replacement(actor, user, reason, opts) do
    with {:ok, user} <- put_platform_role(user, @platform_admin_role),
         :ok <-
           record_user_audit(
             actor,
             "platform.admin.granted",
             user,
             reason,
             %{"previous_role" => nil, "new_role" => @platform_admin_role},
             opts
           ) do
      {:ok, user}
    end
  end

  defp put_platform_role(%User{platform_role: role} = user, role), do: {:ok, user}

  defp put_platform_role(user, role) do
    user
    |> Ecto.Changeset.change(platform_role: role)
    |> Repo.update()
  end

  defp record_bootstrap_audit(user, result) do
    %PlatformAuditEvent{}
    |> PlatformAuditEvent.changeset(%{
      actor_kind: "bootstrap",
      actor_label: "release_rpc",
      action: "platform.admin.bootstrap",
      target_type: "user",
      target_id: user.id,
      reason: "bootstrap",
      metadata: %{"result" => Atom.to_string(result)}
    })
    |> Repo.insert()
    |> audit_result()
  end

  defp record_user_audit(actor, action, target, reason, metadata, opts) do
    %PlatformAuditEvent{}
    |> PlatformAuditEvent.changeset(%{
      actor_kind: "user",
      actor_user_id: actor.id,
      actor_label: actor.email,
      action: action,
      target_type: "user",
      target_id: target.id,
      reason: reason,
      request_id: Keyword.get(opts, :request_id),
      metadata: metadata
    })
    |> Repo.insert()
    |> audit_result()
  end

  defp audit_result({:ok, %PlatformAuditEvent{}}), do: :ok
  defp audit_result({:error, changeset}), do: {:error, changeset}

  defp lock_authority_changes do
    if Repo.in_transaction?() do
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock($1)", [@authority_lock_key])
      :ok
    else
      raise "platform authority lock requires a database transaction"
    end
  end

  defp lock_user(user_id) do
    Repo.one(from user in User, where: user.id == ^user_id, lock: "FOR UPDATE")
  end

  defp lock_user_by_email(email) do
    Repo.one(from user in User, where: user.email == ^email, lock: "FOR UPDATE")
  end

  defp normalize_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, :reason_required}
      reason when byte_size(reason) <= 500 -> {:ok, reason}
      _reason -> {:error, :reason_too_long}
    end
  end

  defp normalize_reason(_reason), do: {:error, :reason_required}

  defp user_id(%User{id: id}), do: user_id(id)

  defp user_id(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp user_id(_id), do: {:error, :not_found}

  defp distinct_users(id, id), do: {:error, :same_user}
  defp distinct_users(_target_id, _replacement_id), do: :ok

  defp not_self(%Scope{user: %User{id: id}}, id), do: {:error, :self_suspension}
  defp not_self(_scope, _target_id), do: :ok

  defp not_suspended(%User{suspended_at: nil}), do: :ok
  defp not_suspended(%User{}), do: {:error, :already_suspended}

  defp disconnect_suspended_sessions({:ok, {_user, tokens}} = result) do
    Accounts.disconnect_sessions(tokens)
    result
  end

  defp disconnect_suspended_sessions(result), do: result

  defp lookup_user(term) do
    id = cast_uuid(term)

    user =
      Repo.one(
        from user in User,
          where: user.email == ^String.downcase(term) or user.id == ^id,
          select: %{
            id: user.id,
            email: user.email,
            kind: user.kind,
            platform_role: user.platform_role,
            confirmed_at: user.confirmed_at,
            suspended_at: user.suspended_at,
            inserted_at: user.inserted_at
          }
      )

    case user do
      nil ->
        nil

      user ->
        Map.merge(user, %{
          organization_memberships:
            Repo.aggregate(
              from(m in OrganizationMembership, where: m.user_id == ^user.id),
              :count
            ),
          workspace_memberships:
            Repo.aggregate(from(m in WorkspaceMembership, where: m.user_id == ^user.id), :count),
          pastes:
            Repo.aggregate(from(p in Paste, where: p.created_by_user_id == ^user.id), :count)
        })
    end
  end

  defp lookup_organization(term) do
    id = cast_uuid(term)

    organization =
      Repo.one(
        from organization in Organization,
          where: organization.slug == ^term or organization.id == ^id,
          select: %{
            id: organization.id,
            name: organization.name,
            slug: organization.slug,
            kind: organization.kind,
            deletion_requested_at: organization.deletion_requested_at,
            inserted_at: organization.inserted_at
          }
      )

    case organization do
      nil ->
        nil

      organization ->
        workspace_ids =
          from(workspace in Workspace,
            where: workspace.organization_id == ^organization.id,
            select: workspace.id
          )

        Map.merge(organization, %{
          members:
            Repo.aggregate(
              from(m in OrganizationMembership, where: m.organization_id == ^organization.id),
              :count
            ),
          workspaces: Repo.aggregate(workspace_ids, :count),
          pastes:
            Repo.aggregate(
              from(p in Paste, where: p.workspace_id in subquery(workspace_ids)),
              :count
            )
        })
    end
  end

  defp lookup_workspace(term) do
    id = cast_uuid(term)

    base_query =
      from workspace in Workspace,
        join: organization in Organization,
        on: organization.id == workspace.organization_id

    query =
      case String.split(term, "/", parts: 2) do
        [organization_slug, workspace_slug] ->
          from [workspace, organization] in base_query,
            where: organization.slug == ^organization_slug and workspace.slug == ^workspace_slug

        _other ->
          from [workspace, _organization] in base_query, where: workspace.id == ^id
      end

    workspace =
      Repo.one(
        from [workspace, organization] in query,
          select: %{
            id: workspace.id,
            name: workspace.name,
            slug: workspace.slug,
            visibility: workspace.visibility,
            external_sharing_policy: workspace.external_sharing_policy,
            is_default: workspace.is_default,
            deletion_requested_at: workspace.deletion_requested_at,
            inserted_at: workspace.inserted_at,
            organization_name: organization.name,
            organization_slug: organization.slug
          }
      )

    case workspace do
      nil ->
        nil

      workspace ->
        Map.merge(workspace, %{
          members:
            Repo.aggregate(
              from(m in WorkspaceMembership, where: m.workspace_id == ^workspace.id),
              :count
            ),
          pastes: Repo.aggregate(from(p in Paste, where: p.workspace_id == ^workspace.id), :count)
        })
    end
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> Ecto.UUID.generate()
    end
  end

  defp page(items, limit, requested_page) do
    current_page = page_number(requested_page)

    %{
      entries: Enum.take(items, limit),
      page: current_page,
      previous_page: if(current_page > 1, do: current_page - 1),
      next_page: if(length(items) > limit, do: current_page + 1)
    }
  end

  defp page_offset(requested_page, limit), do: (page_number(requested_page) - 1) * limit

  defp page_number(page) when is_binary(page) do
    case Integer.parse(page) do
      {page, ""} -> max(page, 1)
      _error -> 1
    end
  end

  defp page_number(page) when is_integer(page), do: max(page, 1)
  defp page_number(_page), do: 1

  defp page_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {limit, ""} -> page_limit(limit)
      _error -> @default_page_size
    end
  end

  defp page_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_page_size)
  defp page_limit(_limit), do: @default_page_size

  defp platform_audit_event_query(nil) do
    {:ok, from(event in PlatformAuditEvent, order_by: [desc: event.inserted_at, desc: event.id])}
  end

  defp platform_audit_event_query(cursor) do
    with {:ok, cursor_id} <- Ecto.UUID.cast(cursor),
         %PlatformAuditEvent{} = cursor_event <- Repo.get(PlatformAuditEvent, cursor_id) do
      {:ok,
       from(event in PlatformAuditEvent,
         where:
           event.inserted_at < ^cursor_event.inserted_at or
             (event.inserted_at == ^cursor_event.inserted_at and event.id < ^cursor_event.id),
         order_by: [desc: event.inserted_at, desc: event.id]
       )}
    else
      _error -> {:error, :not_found}
    end
  end

  defp notify_platform_authority_change({:ok, %User{id: user_id}} = result) do
    broadcast_platform_authority_change(user_id)
    result
  end

  defp notify_platform_authority_change({:ok, %{revoked: %User{id: revoked_id}}} = result) do
    broadcast_platform_authority_change(revoked_id)
    result
  end

  defp notify_platform_authority_change(result), do: result

  defp broadcast_platform_authority_change(user_id) do
    Phoenix.PubSub.broadcast(
      Textbin.PubSub,
      platform_authority_topic(user_id),
      :platform_authority_changed
    )
  end

  defp platform_authority_topic(user_id), do: "platform_authority:#{user_id}"
end
