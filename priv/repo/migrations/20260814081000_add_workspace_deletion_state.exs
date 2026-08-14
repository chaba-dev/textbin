defmodule Textbin.Repo.Migrations.AddWorkspaceDeletionState do
  use Ecto.Migration

  def change do
    alter table(:workspaces) do
      add :deletion_requested_at, :utc_datetime_usec
    end

    create index(:workspaces, [:deletion_requested_at],
             where: "deletion_requested_at IS NOT NULL"
           )
  end
end
