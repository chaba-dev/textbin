defmodule Textbin.Repo.Migrations.AddKindToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :kind, :string, null: false, default: "registered"
    end

    create index(:users, [:kind])
  end

  def down do
    drop index(:users, [:kind])

    alter table(:users) do
      remove :kind
    end
  end
end
