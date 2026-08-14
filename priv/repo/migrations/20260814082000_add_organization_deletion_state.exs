defmodule Textbin.Repo.Migrations.AddOrganizationDeletionState do
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add :deletion_requested_at, :utc_datetime_usec
    end

    create index(:organizations, [:deletion_requested_at],
             where: "deletion_requested_at IS NOT NULL"
           )
  end
end
