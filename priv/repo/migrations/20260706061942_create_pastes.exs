defmodule Textbin.Repo.Migrations.CreatePastes do
  use Ecto.Migration

  def up do
    create table(:pastes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :content, :text, null: false

      timestamps(type: :utc_datetime)
    end
  end

  def down do
    drop table(:pastes)
  end
end
