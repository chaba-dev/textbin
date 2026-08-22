defmodule Textbin.Repo.Migrations.AddPlatformAdministration do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :platform_role, :string
      add :suspended_at, :utc_datetime
    end

    create constraint(:users, :users_platform_role_must_be_supported,
             check: "platform_role IS NULL OR platform_role = 'admin'"
           )

    create index(:users, [:platform_role], where: "platform_role IS NOT NULL")
    create index(:users, [:suspended_at], where: "suspended_at IS NOT NULL")

    create table(:platform_audit_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :actor_kind, :string, null: false
      add :actor_user_id, :binary_id
      add :actor_label, :string, null: false
      add :action, :string, null: false
      add :target_type, :string, null: false
      add :target_id, :binary_id, null: false
      add :reason, :text, null: false
      add :request_id, :string
      add :metadata, :map, null: false, default: %{}
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create constraint(:platform_audit_events, :platform_audit_events_actor_must_be_valid,
             check: """
             (actor_kind = 'user' AND actor_user_id IS NOT NULL) OR
             (actor_kind = 'bootstrap' AND actor_user_id IS NULL)
             """
           )

    create index(:platform_audit_events, [:inserted_at, :id])
    create index(:platform_audit_events, [:actor_user_id])
    create index(:platform_audit_events, [:target_type, :target_id])

    execute(
      """
      CREATE FUNCTION prevent_platform_audit_event_changes()
      RETURNS trigger AS $$
      BEGIN
        RAISE EXCEPTION 'platform audit events are append-only';
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION prevent_platform_audit_event_changes()"
    )

    execute(
      """
      CREATE TRIGGER platform_audit_events_are_append_only
      BEFORE UPDATE OR DELETE ON platform_audit_events
      FOR EACH ROW EXECUTE FUNCTION prevent_platform_audit_event_changes()
      """,
      "DROP TRIGGER platform_audit_events_are_append_only ON platform_audit_events"
    )
  end
end
