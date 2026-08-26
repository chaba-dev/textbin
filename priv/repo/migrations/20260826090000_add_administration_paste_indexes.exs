defmodule Textbin.Repo.Migrations.AddAdministrationPasteIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    execute(
      """
      UPDATE pastes
      SET size_bytes = octet_length(data),
          sha256 = sha256(convert_to(data, 'UTF8'))
      WHERE data IS NOT NULL AND (size_bytes IS NULL OR sha256 IS NULL)
      """,
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
