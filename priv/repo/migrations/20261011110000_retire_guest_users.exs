defmodule Textbin.Repo.Migrations.RetireGuestUsers do
  use Ecto.Migration

  # Guest accounts are gone. Their content lives partly in object storage,
  # which a migration cannot reach, so this hides it and hands it to the
  # regular purge: pastes in a workspace marked for deletion are hard-deleted,
  # storage first, on the cleaner's next run. The inert user rows stay until a
  # later cleanup; nothing can sign in as them without a session.
  def up do
    execute """
    UPDATE workspaces AS w
    SET deletion_requested_at = COALESCE(w.deletion_requested_at, now()), updated_at = now()
    FROM organizations AS o, users AS u
    WHERE w.organization_id = o.id AND o.personal_owner_id = u.id AND u.kind = 'guest'
    """

    execute """
    UPDATE organizations AS o
    SET deletion_requested_at = COALESCE(o.deletion_requested_at, now()), updated_at = now()
    FROM users AS u
    WHERE o.personal_owner_id = u.id AND u.kind = 'guest'
    """

    execute """
    UPDATE pastes AS p
    SET expires_at = now(), updated_at = now()
    FROM workspaces AS w, organizations AS o, users AS u
    WHERE p.workspace_id = w.id AND w.organization_id = o.id AND o.personal_owner_id = u.id
      AND u.kind = 'guest' AND (p.expires_at IS NULL OR p.expires_at > now())
    """

    execute """
    DELETE FROM users_tokens AS t USING users AS u
    WHERE t.user_id = u.id AND u.kind = 'guest'
    """
  end

  # Nothing to undo: guest content is either still hidden or already purged.
  def down, do: :ok
end
