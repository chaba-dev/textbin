defmodule Textbin.Repo.Migrations.DeleteRetiredGuestUsers do
  use Ecto.Migration

  # Second half of RetireGuestUsers, which hid guest content and marked each
  # guest's personal workspace for deletion. Deleting a guest user cascades to
  # its personal organization, workspace, memberships and tokens.
  #
  # Pastes restrict workspace deletion, so they go first. Inline pastes live
  # only in this database and are deleted here, which is all the cleaner would
  # do for them. Pastes with a storage key also have an object outside the
  # database that a migration cannot reach; those are left to the cleaner, and
  # their guest is skipped until a later cleanup. On an install where the
  # cleaner has already run since RetireGuestUsers, nothing is skipped.
  def up do
    execute """
    DELETE FROM pastes AS p
    USING workspaces AS w, organizations AS o, users AS u
    WHERE p.workspace_id = w.id AND w.organization_id = o.id AND o.personal_owner_id = u.id
      AND u.kind = 'guest' AND p.storage_key IS NULL
    """

    execute """
    DELETE FROM users AS u
    WHERE u.kind = 'guest'
      AND NOT EXISTS (
        SELECT 1
        FROM pastes AS p
        JOIN workspaces AS w ON w.id = p.workspace_id
        JOIN organizations AS o ON o.id = w.organization_id
        WHERE o.personal_owner_id = u.id
      )
    """
  end

  # The rows were already hidden and scheduled for purging; nothing to restore.
  def down, do: :ok
end
