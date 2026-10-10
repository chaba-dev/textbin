defmodule Textbin.Repo.Migrations.AddPasteLifecycle do
  use Ecto.Migration

  # A paste is active, then removed (deleted by someone, expired, or taken down
  # by a platform administrator), then hard deleted. Deleted and expired pastes
  # stay restorable for the workspace's recovery window; moderated ones never do.
  def change do
    alter table(:pastes) do
      add :removed_at, :utc_datetime_usec
      add :removal_reason, :text
      add :removed_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create constraint(:pastes, :pastes_removal_reason_check,
             check:
               "(removed_at IS NULL AND removal_reason IS NULL) OR " <>
                 "(removed_at IS NOT NULL AND removal_reason IN ('deleted', 'moderated'))"
           )

    create index(:pastes, [:workspace_id, :removed_at], where: "removed_at IS NOT NULL")

    alter table(:workspaces) do
      add :recovery_window_days, :integer, null: false, default: 30
    end

    create constraint(:workspaces, :workspaces_recovery_window_days_check,
             check: "recovery_window_days BETWEEN 1 AND 365"
           )
  end
end
