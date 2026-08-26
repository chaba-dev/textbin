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
  alias Textbin.Repo

  @platform_admin_role "admin"
  @authority_lock_key 8_174_021_483_001

  @doc "Returns the current user when the scope has active platform authority."
  def authorize_platform_admin(%Scope{user: %User{id: user_id}}) do
    case Repo.get(User, user_id) do
      %User{} = user -> authorize_active_admin(user)
      nil -> {:error, :forbidden}
    end
  end

  def authorize_platform_admin(_scope), do: {:error, :forbidden}

  @doc "Subscribes the caller to authority changes for its current user."
  def subscribe_to_platform_authority(%Scope{user: %User{id: user_id}}) do
    Phoenix.PubSub.subscribe(Textbin.PubSub, platform_authority_topic(user_id))
  end

  def subscribe_to_platform_authority(_scope), do: {:error, :forbidden}

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
      |> notify_platform_authority_change()
    end
  end

  @doc "Revokes platform authority while preserving one active administrator."
  def revoke_platform_admin(scope, target, reason, opts \\ []) do
    with {:ok, reason} <- normalize_reason(reason),
         {:ok, target_id} <- user_id(target) do
      authority_transaction(
        scope,
        &revoke_platform_admin_in_transaction(&1, target_id, reason, opts)
      )
      |> notify_platform_authority_change()
    end
  end

  @doc "Grants a replacement and revokes an administrator in one transaction."
  def transfer_platform_admin(scope, target, replacement, reason, opts \\ []) do
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
      |> notify_platform_authority_change()
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
        |> notify_platform_authority_change()
      end

    disconnect_suspended_sessions(result)
  end

  @doc "Restores a suspended account without restoring its revoked tokens."
  def restore_user(scope, target, reason, opts \\ []) do
    with {:ok, reason} <- normalize_reason(reason),
         {:ok, target_id} <- user_id(target) do
      authority_transaction(scope, &restore_user_in_transaction(&1, target_id, reason, opts))
      |> notify_platform_authority_change()
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

  defp notify_platform_authority_change({:ok, %User{id: user_id}} = result) do
    broadcast_platform_authority_change(user_id)
    result
  end

  defp notify_platform_authority_change({:ok, %{revoked: %User{id: user_id}}} = result) do
    broadcast_platform_authority_change(user_id)
    result
  end

  defp notify_platform_authority_change({:ok, {%User{id: user_id}, _tokens}} = result) do
    broadcast_platform_authority_change(user_id)
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
