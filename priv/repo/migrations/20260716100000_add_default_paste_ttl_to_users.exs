defmodule Textbin.Repo.Migrations.AddDefaultPasteTtlToUsers do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :default_paste_ttl, :string, null: false, default: "never"
    end
  end

  def down do
    alter table(:users) do
      remove :default_paste_ttl
    end
  end
end
