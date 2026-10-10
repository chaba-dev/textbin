defmodule Textbin.Repo.Migrations.AddPasteTitleAndReference do
  use Ecto.Migration

  # Both columns are optional. Existing rows keep a NULL title and render as
  # "Untitled paste"; new pastes get a title derived from their first line when
  # the caller does not supply one, so no backfill is needed.
  def change do
    alter table(:pastes) do
      add :title, :string, size: 200
      add :reference_url, :string, size: 2048
    end
  end
end
