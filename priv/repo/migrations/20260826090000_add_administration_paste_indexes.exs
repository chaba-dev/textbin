defmodule Textbin.Repo.Migrations.AddAdministrationPasteIndexes do
  use Ecto.Migration

  def change do
    create index(:pastes, [:visibility, :inserted_at, :id],
             name: :pastes_admin_recent_visibility_index
           )

    create index(:pastes, [:size_bytes, :inserted_at, :id], name: :pastes_admin_largest_index)
  end
end
