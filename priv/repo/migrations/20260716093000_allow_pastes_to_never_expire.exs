defmodule Textbin.Repo.Migrations.AllowPastesToNeverExpire do
  use Ecto.Migration

  def up do
    alter table(:pastes) do
      modify :expires_at, :utc_datetime_usec,
        precision: 3,
        null: true,
        default: nil,
        from: {:utc_datetime_usec, precision: 3, null: false}
    end
  end

  def down do
    execute "UPDATE pastes SET expires_at = now() + interval '7 days' WHERE expires_at IS NULL"

    alter table(:pastes) do
      modify :expires_at, :utc_datetime_usec,
        precision: 3,
        null: false,
        default: fragment("(now() + interval '7 days')"),
        from: {:utc_datetime_usec, precision: 3, null: true}
    end
  end
end
