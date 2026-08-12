defmodule Textbin.Repo.Migrations.MovePastesToWorkspaces do
  use Ecto.Migration

  def up do
    alter table(:pastes) do
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :restrict)

      add :created_by_user_id,
          references(:users, type: :binary_id, on_delete: :nilify_all)
    end

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

    alter table(:pastes) do
      remove :user_id
    end
  end

  def down do
    alter table(:pastes) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all)
    end

    execute """
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM pastes AS paste
        WHERE paste.created_by_user_id IS NULL
           OR NOT EXISTS (
             SELECT 1
             FROM workspaces AS workspace
             JOIN organizations AS organization
               ON organization.id = workspace.organization_id
             WHERE workspace.id = paste.workspace_id
               AND workspace.is_default
               AND organization.personal_owner_id = paste.created_by_user_id
           )
      ) THEN
        RAISE EXCEPTION
          'cannot roll back workspace paste ownership with non-personal workspace pastes';
      END IF;
    END;
    $$
    """

    execute """
    UPDATE pastes
    SET user_id = created_by_user_id
    """

    alter table(:pastes) do
      modify :user_id, :binary_id, null: false
    end

    drop index(:pastes, [:created_by_user_id])
    drop index(:pastes, [:workspace_id, :inserted_at])

    alter table(:pastes) do
      remove :created_by_user_id
      remove :workspace_id
    end
  end
end
