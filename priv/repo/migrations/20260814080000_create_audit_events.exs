defmodule Textbin.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :organization_id, :binary_id, null: false
      add :actor_user_id, :binary_id, null: false
      add :action, :string, null: false
      add :target_type, :string, null: false
      add :target_id, :binary_id, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create index(:audit_events, [:organization_id, :inserted_at])
    create index(:audit_events, [:actor_user_id])
    create index(:audit_events, [:target_type, :target_id])
  end
end
