defmodule Textbin.Repo.Migrations.AddUserIdToPastes do
  use Ecto.Migration

  def up do
    alter table(:pastes) do
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
    end

    create index(:pastes, [:user_id])
  end

  def down do
    drop index(:pastes, [:user_id])

    alter table(:pastes) do
      remove :user_id
    end
  end
end
