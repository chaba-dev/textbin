defmodule Textbin.Repo.Migrations.CreatePendingUploads do
  use Ecto.Migration

  def change do
    create table(:pending_uploads, primary_key: false) do
      add :storage_key, :string, primary_key: true
      add :claimed_at, :utc_datetime_usec
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:pending_uploads, [:inserted_at])
  end
end
