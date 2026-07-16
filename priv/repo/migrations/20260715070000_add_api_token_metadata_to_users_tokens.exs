defmodule Textbin.Repo.Migrations.AddApiTokenMetadataToUsersTokens do
  use Ecto.Migration

  def up do
    alter table(:users_tokens) do
      add :name, :string
      add :last_used_at, :utc_datetime
    end
  end

  def down do
    alter table(:users_tokens) do
      remove :last_used_at
      remove :name
    end
  end
end
