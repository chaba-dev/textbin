defmodule Textbin.Repo.Migrations.MovePasteContentToStorage do
  use Ecto.Migration

  def change do
    alter table(:pastes) do
      modify :data, :text, null: true, from: {:text, null: false}
      add :storage_key, :string
      add :size_bytes, :bigint
      add :sha256, :binary
    end

    create constraint(:pastes, :pastes_content_location_check,
             check: "data IS NOT NULL OR storage_key IS NOT NULL"
           )

    create unique_index(:pastes, [:storage_key], where: "storage_key IS NOT NULL")
  end
end
