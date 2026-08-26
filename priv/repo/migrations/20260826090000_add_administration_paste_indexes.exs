defmodule Textbin.Repo.Migrations.AddAdministrationPasteIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    execute(
      "UPDATE pastes SET size_bytes = octet_length(data) WHERE size_bytes IS NULL AND data IS NOT NULL",
      "SELECT 1"
    )

    create index(:pastes, [asc: :visibility, desc: :inserted_at, desc: :id],
             name: :pastes_admin_recent_visibility_index,
             concurrently: true
           )

    create index(
             :pastes,
             [desc_nulls_last: :size_bytes, desc: :inserted_at, desc: :id],
             name: :pastes_admin_largest_index,
             concurrently: true
           )
  end
end
