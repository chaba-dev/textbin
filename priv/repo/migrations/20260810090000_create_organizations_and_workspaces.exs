defmodule Textbin.Repo.Migrations.CreateOrganizationsAndWorkspaces do
  use Ecto.Migration

  def up do
    create table(:organizations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :slug, :string, null: false
      add :kind, :string, null: false

      add :personal_owner_id,
          references(:users, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organizations, [:slug])
    create unique_index(:organizations, [:personal_owner_id])

    create constraint(:organizations, :organizations_kind_check,
             check: "kind IN ('personal', 'team')"
           )

    create constraint(:organizations, :organizations_personal_owner_check,
             check:
               "(kind = 'personal' AND personal_owner_id IS NOT NULL) OR " <>
                 "(kind = 'team' AND personal_owner_id IS NULL)"
           )

    create table(:organization_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :role, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organization_memberships, [:organization_id, :user_id])
    create index(:organization_memberships, [:user_id])

    create constraint(:organization_memberships, :organization_memberships_role_check,
             check: "role IN ('owner', 'admin', 'member')"
           )

    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :organization_id,
          references(:organizations, type: :binary_id, on_delete: :delete_all),
          null: false

      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :name, :string, null: false
      add :slug, :string, null: false
      add :visibility, :string, null: false, default: "open"
      add :is_default, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspaces, [:organization_id, :slug])

    create unique_index(:workspaces, [:organization_id],
             where: "is_default",
             name: :workspaces_one_default_per_organization
           )

    create constraint(:workspaces, :workspaces_visibility_check,
             check: "visibility IN ('open', 'private')"
           )

    create constraint(:workspaces, :workspaces_default_visibility_check,
             check: "NOT is_default OR visibility = 'open'"
           )

    create table(:workspace_memberships, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          null: false

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :created_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :role, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:workspace_memberships, [:workspace_id, :user_id])
    create index(:workspace_memberships, [:user_id])
    create index(:workspace_memberships, [:workspace_id, :role])

    create constraint(:workspace_memberships, :workspace_memberships_role_check,
             check: "role IN ('owner', 'member')"
           )

    # Block legacy instances from inserting a user between the backfill snapshot
    # and trigger installation. Waiting inserts resume with the trigger active
    # after this transactional migration commits.
    execute "LOCK TABLE users IN SHARE ROW EXCLUSIVE MODE"

    backfill_personal_organizations()
    create_user_provisioning_trigger()
  end

  def down do
    execute "DROP TRIGGER users_provision_personal_organization ON users"
    execute "DROP FUNCTION provision_personal_organization()"

    drop table(:workspace_memberships)
    drop table(:workspaces)
    drop table(:organization_memberships)
    drop table(:organizations)
  end

  defp backfill_personal_organizations do
    execute """
    INSERT INTO organizations
      (id, name, slug, kind, personal_owner_id, inserted_at, updated_at)
    SELECT
      users.id,
      'Personal',
      'personal-' || users.id::text,
      'personal',
      users.id,
      NOW(),
      NOW()
    FROM users
    """

    execute """
    INSERT INTO organization_memberships
      (id, organization_id, user_id, role, inserted_at, updated_at)
    SELECT
      md5(users.id::text || ':organization-membership')::uuid,
      users.id,
      users.id,
      'owner',
      NOW(),
      NOW()
    FROM users
    """

    execute """
    INSERT INTO workspaces
      (id, organization_id, created_by_id, name, slug, visibility, is_default, inserted_at, updated_at)
    SELECT
      md5(users.id::text || ':default-workspace')::uuid,
      users.id,
      users.id,
      'Default',
      'default',
      'open',
      TRUE,
      NOW(),
      NOW()
    FROM users
    """

    execute """
    INSERT INTO workspace_memberships
      (id, workspace_id, user_id, created_by_id, role, inserted_at, updated_at)
    SELECT
      md5(users.id::text || ':workspace-membership')::uuid,
      md5(users.id::text || ':default-workspace')::uuid,
      users.id,
      users.id,
      'owner',
      NOW(),
      NOW()
    FROM users
    """
  end

  # The trigger keeps this migration forward-compatible with old application
  # instances that may create users while a rolling deployment is in progress.
  defp create_user_provisioning_trigger do
    execute """
    CREATE FUNCTION provision_personal_organization()
    RETURNS TRIGGER AS $$
    DECLARE
      default_workspace_id uuid := md5(NEW.id::text || ':default-workspace')::uuid;
    BEGIN
      INSERT INTO organizations
        (id, name, slug, kind, personal_owner_id, inserted_at, updated_at)
      VALUES
        (NEW.id, 'Personal', 'personal-' || NEW.id::text, 'personal', NEW.id, NOW(), NOW());

      INSERT INTO organization_memberships
        (id, organization_id, user_id, role, inserted_at, updated_at)
      VALUES
        (md5(NEW.id::text || ':organization-membership')::uuid,
         NEW.id, NEW.id, 'owner', NOW(), NOW());

      INSERT INTO workspaces
        (id, organization_id, created_by_id, name, slug, visibility, is_default, inserted_at, updated_at)
      VALUES
        (default_workspace_id, NEW.id, NEW.id, 'Default', 'default', 'open', TRUE, NOW(), NOW());

      INSERT INTO workspace_memberships
        (id, workspace_id, user_id, created_by_id, role, inserted_at, updated_at)
      VALUES
        (md5(NEW.id::text || ':workspace-membership')::uuid,
         default_workspace_id, NEW.id, NEW.id, 'owner', NOW(), NOW());

      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER users_provision_personal_organization
    AFTER INSERT ON users
    FOR EACH ROW EXECUTE FUNCTION provision_personal_organization()
    """
  end
end
