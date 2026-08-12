defmodule Textbin.Repo.Migrations.DropPreproductionCompatibilityTriggers do
  use Ecto.Migration

  def up do
    execute "DROP TRIGGER IF EXISTS pastes_sync_workspace_ownership ON pastes"
    execute "DROP FUNCTION IF EXISTS sync_paste_workspace_ownership()"
    execute "DROP TRIGGER IF EXISTS users_provision_personal_organization ON users"
    execute "DROP FUNCTION IF EXISTS provision_personal_organization()"
    execute "ALTER TABLE pastes DROP COLUMN IF EXISTS user_id CASCADE"
  end

  def down, do: :ok
end
