defmodule Textbin.Repo.Migrations.AddContentTypeToPastes do
  use Ecto.Migration

  def change do
    alter table(:pastes) do
      add :content_type, :string, null: false, default: "text/plain"
    end
  end
end
