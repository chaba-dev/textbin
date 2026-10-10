defmodule Textbin.Repo.Migrations.AddAppearanceToUsers do
  use Ecto.Migration

  # Appearance is a personal preference, never an organization setting.
  def change do
    alter table(:users) do
      add :theme, :text, null: false, default: "harbor"
      add :color_mode, :text, null: false, default: "auto"
    end
  end
end
