defmodule Textbin.Repo.Migrations.AddPasteAudiencePolicy do
  use Ecto.Migration

  def up do
    drop constraint(:pastes, :pastes_visibility_check)

    execute "UPDATE pastes SET visibility = 'workspace' WHERE visibility = 'private'"

    alter table(:pastes) do
      modify :visibility, :string, default: "workspace"
    end

    create constraint(:pastes, :pastes_visibility_check,
             check: "visibility IN ('workspace', 'unlisted', 'public')"
           )

    alter table(:workspaces) do
      add :external_sharing_policy, :string, null: false, default: "disabled"
    end

    execute """
    UPDATE workspaces
    SET external_sharing_policy = 'public'
    WHERE visibility = 'open'
    """

    execute """
    UPDATE pastes
    SET visibility = 'workspace'
    FROM workspaces
    WHERE pastes.workspace_id = workspaces.id
      AND workspaces.external_sharing_policy = 'disabled'
    """

    create constraint(:workspaces, :workspaces_external_sharing_policy_check,
             check: "external_sharing_policy IN ('disabled', 'unlisted', 'public')"
           )
  end

  def down do
    drop constraint(:workspaces, :workspaces_external_sharing_policy_check)

    alter table(:workspaces) do
      remove :external_sharing_policy
    end

    drop constraint(:pastes, :pastes_visibility_check)

    execute "UPDATE pastes SET visibility = 'private' WHERE visibility = 'workspace'"

    alter table(:pastes) do
      modify :visibility, :string, default: "private"
    end

    create constraint(:pastes, :pastes_visibility_check,
             check: "visibility IN ('private', 'unlisted', 'public')"
           )
  end
end
