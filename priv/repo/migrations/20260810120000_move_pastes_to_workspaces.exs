defmodule Textbin.Repo.Migrations.MovePastesToWorkspaces do
  use Ecto.Migration

  def up do
    alter table(:pastes) do
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :restrict)

      add :created_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    # Keep the legacy column writable for old instances during rollout, but it
    # is no longer an ownership boundary and must not cascade shared paste data.
    drop constraint(:pastes, "pastes_user_id_fkey")

    alter table(:pastes) do
      modify :user_id, :binary_id, null: true
    end

    execute """
    ALTER TABLE pastes
    ADD CONSTRAINT pastes_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE SET NULL
    """

    # Prevent old instances from inserting between the backfill snapshot and
    # compatibility-trigger installation.
    execute "LOCK TABLE pastes IN SHARE ROW EXCLUSIVE MODE"

    execute """
    UPDATE pastes AS paste
    SET workspace_id = workspace.id,
        created_by_user_id = paste.user_id
    FROM organizations AS organization
    JOIN workspaces AS workspace
      ON workspace.organization_id = organization.id AND workspace.is_default
    WHERE organization.personal_owner_id = paste.user_id
    """

    alter table(:pastes) do
      modify :workspace_id, :binary_id, null: false
    end

    create index(:pastes, [:workspace_id, :inserted_at])
    create index(:pastes, [:created_by_user_id])

    create_compatibility_trigger()
  end

  def down do
    execute "LOCK TABLE pastes IN SHARE ROW EXCLUSIVE MODE"

    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM pastes AS paste
        WHERE paste.user_id IS NULL
           OR NOT EXISTS (
             SELECT 1
             FROM workspaces AS workspace
             JOIN organizations AS organization
               ON organization.id = workspace.organization_id
             WHERE workspace.id = paste.workspace_id
               AND workspace.is_default
               AND organization.personal_owner_id = paste.user_id
           )
      ) THEN
        RAISE EXCEPTION
          'cannot roll back workspace paste ownership with non-personal workspace pastes';
      END IF;
    END;
    $$
    """

    execute "DROP TRIGGER pastes_sync_workspace_ownership ON pastes"
    execute "DROP FUNCTION sync_paste_workspace_ownership()"

    drop index(:pastes, [:created_by_user_id])
    drop index(:pastes, [:workspace_id, :inserted_at])

    alter table(:pastes) do
      remove :created_by_user_id
      remove :workspace_id
    end

    drop constraint(:pastes, "pastes_user_id_fkey")

    alter table(:pastes) do
      modify :user_id, :binary_id, null: false
    end

    execute """
    ALTER TABLE pastes
    ADD CONSTRAINT pastes_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
    """
  end

  defp create_compatibility_trigger do
    execute """
    CREATE FUNCTION sync_paste_workspace_ownership()
    RETURNS TRIGGER AS $$
    BEGIN
      NEW.created_by_user_id := COALESCE(NEW.created_by_user_id, NEW.user_id);
      NEW.user_id := COALESCE(NEW.user_id, NEW.created_by_user_id);

      IF NEW.workspace_id IS NULL THEN
        SELECT workspace.id INTO NEW.workspace_id
        FROM organizations AS organization
        JOIN workspaces AS workspace
          ON workspace.organization_id = organization.id AND workspace.is_default
        WHERE organization.personal_owner_id = NEW.created_by_user_id;
      END IF;

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER pastes_sync_workspace_ownership
    BEFORE INSERT ON pastes
    FOR EACH ROW EXECUTE FUNCTION sync_paste_workspace_ownership()
    """
  end
end
