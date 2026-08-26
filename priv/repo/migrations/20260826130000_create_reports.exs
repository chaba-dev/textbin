defmodule Textbin.Repo.Migrations.CreateReports do
  use Ecto.Migration

  def change do
    create table(:reports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :paste_id, :binary_id, null: false
      add :reporter_user_id, :binary_id, null: false
      add :category, :string, null: false
      add :notes, :text
      add :status, :string, null: false, default: "open"
      add :resolution_reason, :text
      add :resolved_by_user_id, :binary_id
      add :resolved_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:reports, :reports_category_must_be_supported,
             check: "category IN ('spam', 'malware', 'harassment', 'copyright', 'other')"
           )

    create constraint(:reports, :reports_status_must_be_supported,
             check: "status IN ('open', 'actioned', 'dismissed')"
           )

    create constraint(:reports, :reports_resolution_must_be_consistent,
             check: """
             (status = 'open' AND resolution_reason IS NULL AND
               resolved_by_user_id IS NULL AND resolved_at IS NULL) OR
             (status IN ('actioned', 'dismissed') AND resolution_reason IS NOT NULL AND
               resolved_by_user_id IS NOT NULL AND resolved_at IS NOT NULL)
             """
           )

    create index(:reports, [:status, :inserted_at, :id], name: :reports_queue_index)
    create index(:reports, [:paste_id])

    create unique_index(:reports, [:paste_id, :reporter_user_id],
             name: :reports_one_open_per_reporter_index,
             where: "status = 'open'"
           )
  end
end
