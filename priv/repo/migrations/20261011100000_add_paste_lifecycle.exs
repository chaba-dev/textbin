defmodule Textbin.Repo.Migrations.AddPasteLifecycle do
  use Ecto.Migration

  # A paste is active, then removed (deleted by someone, expired, or taken down
  # by a platform administrator), then hard deleted. Deleted and expired pastes
  # stay restorable for the workspace's recovery window; moderated ones never do.
  def up do
    alter table(:pastes) do
      add :removed_at, :utc_datetime_usec
      add :removal_reason, :text
      add :removed_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create constraint(:pastes, :pastes_removal_reason_check,
             check:
               "(removed_at IS NULL AND removal_reason IS NULL) OR " <>
                 "(removed_at IS NOT NULL AND removal_reason IN ('deleted', 'moderated', 'purging'))"
           )

    create index(:pastes, [:workspace_id, :removed_at], where: "removed_at IS NOT NULL")

    alter table(:workspaces) do
      add :recovery_window_days, :integer, null: false, default: 30
    end

    create constraint(:workspaces, :workspaces_recovery_window_days_check,
             check: "recovery_window_days BETWEEN 1 AND 365"
           )

    # Older takedowns used expiration as their tombstone. Preserve that intent
    # instead of letting authors restore moderated content after upgrading.
    execute """
    UPDATE pastes AS p
    SET removed_at = audit.removed_at, removal_reason = 'moderated'
    FROM (
      SELECT target_id, MAX(inserted_at) AS removed_at
      FROM platform_audit_events
      WHERE action = 'platform.paste.deleted' AND target_type = 'paste'
      GROUP BY target_id
    ) AS audit
    WHERE p.id = audit.target_id
    """
  end

  def down do
    # Old readers understand only expiration. Never republish removed content
    # on rollback, and keep storage keys for the old storage-first cleaner.
    execute """
    UPDATE pastes
    SET expires_at = LEAST(COALESCE(expires_at, timezone('UTC', now())), timezone('UTC', now()))
    WHERE removed_at IS NOT NULL
    """

    drop constraint(:workspaces, :workspaces_recovery_window_days_check)
    alter table(:workspaces), do: remove(:recovery_window_days)
    drop index(:pastes, [:workspace_id, :removed_at], where: "removed_at IS NOT NULL")
    drop constraint(:pastes, :pastes_removal_reason_check)

    alter table(:pastes) do
      remove :removed_by_user_id
      remove :removal_reason
      remove :removed_at
    end
  end
end
