defmodule Textbin.Repo.Migrations.AddExpiresAtToPastes do
  use Ecto.Migration

  def up do
    alter table(:pastes) do
      add :expires_at, :utc_datetime_usec, precision: 3
    end

    create index(:pastes, [:expires_at])
  end

  def down do
    drop index(:pastes, [:expires_at])

    alter table(:pastes) do
      remove :expires_at
    end
  end
end
