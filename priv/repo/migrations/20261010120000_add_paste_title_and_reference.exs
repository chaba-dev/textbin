defmodule Textbin.Repo.Migrations.AddPasteTitleAndReference do
  use Ecto.Migration

  # Both columns are optional. Existing rows keep a NULL title and render as
  # "Untitled paste"; new pastes get a title derived from their first line when
  # the caller does not supply one, so no backfill is needed.
  def change do
    alter table(:pastes) do
      # Application limits count graphemes, not PostgreSQL's codepoints.
      add :title, :text
      add :reference_url, :text
    end
  end
end
