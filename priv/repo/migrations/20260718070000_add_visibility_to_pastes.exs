defmodule Textbin.Repo.Migrations.AddVisibilityToPastes do
  use Ecto.Migration

  def up do
    alter table(:pastes) do
      add :visibility, :string, null: false, default: "private"
    end

    create constraint(:pastes, :pastes_visibility_check,
             check: "visibility IN ('private', 'unlisted', 'public')"
           )

    create index(:pastes, [:visibility])
  end

  def down do
    drop index(:pastes, [:visibility])
    drop constraint(:pastes, :pastes_visibility_check)

    alter table(:pastes) do
      remove :visibility
    end
  end
end
