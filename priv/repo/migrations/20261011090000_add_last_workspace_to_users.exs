defmodule Textbin.Repo.Migrations.AddLastWorkspaceToUsers do
  use Ecto.Migration

  # Home lands on the workspace someone used last. A removed workspace simply
  # clears the pointer, and home falls back to the personal workspace.
  def change do
    alter table(:users) do
      add :last_workspace_id, references(:workspaces, type: :binary_id, on_delete: :nilify_all)
    end
  end
end
