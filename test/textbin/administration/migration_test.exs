defmodule Textbin.Administration.MigrationTest do
  use ExUnit.Case, async: false

  alias Textbin.MigrationRepo

  @foundation_version 20_260_822_090_000
  @administration_indexes_version 20_260_826_090_000

  test "backfills inline sizes and creates administration indexes online" do
    database = "textbin_admin_migration_#{Ecto.UUID.generate()}"
    {:ok, admin} = Postgrex.start_link(admin_config())
    Process.unlink(admin)
    Postgrex.query!(admin, ~s(CREATE DATABASE "#{database}"), [])

    on_exit(fn ->
      Postgrex.query!(admin, "DROP DATABASE IF EXISTS \"#{database}\" WITH (FORCE)", [])
      if Process.alive?(admin), do: GenServer.stop(admin)
    end)

    previous_config = Application.get_env(:textbin, MigrationRepo)
    Application.put_env(:textbin, MigrationRepo, repo_config(database))

    on_exit(fn -> restore_repo_config(previous_config) end)

    {:ok, repo} = MigrationRepo.start_link()
    Process.unlink(repo)
    on_exit(fn -> if Process.alive?(repo), do: GenServer.stop(repo) end)

    migrations = Path.expand("../../../priv/repo/migrations", __DIR__)
    Ecto.Migrator.run(MigrationRepo, migrations, :up, to: @foundation_version)

    paste_id = insert_legacy_inline_paste()
    Ecto.Migrator.run(MigrationRepo, migrations, :up, to: @administration_indexes_version)

    assert %{rows: [[21]]} =
             MigrationRepo.query!("SELECT size_bytes FROM pastes WHERE id = $1::uuid", [
               uuid(paste_id)
             ])

    assert index_definition("pastes_admin_recent_visibility_index") =~
             "(visibility, inserted_at DESC, id DESC)"

    assert index_definition("pastes_admin_largest_index") =~
             "(size_bytes DESC NULLS LAST, inserted_at DESC, id DESC)"

    assert MigrationRepo.config()[:migration_lock] == :pg_advisory_lock
    migration = Textbin.Repo.Migrations.AddAdministrationPasteIndexes
    assert apply(migration, :__migration__, [])[:disable_ddl_transaction]
  end

  defp insert_legacy_inline_paste do
    user_id = Ecto.UUID.generate()
    organization_id = Ecto.UUID.generate()
    workspace_id = Ecto.UUID.generate()
    paste_id = Ecto.UUID.generate()

    MigrationRepo.query!(
      "INSERT INTO users (id, email, confirmed_at, inserted_at, updated_at) VALUES ($1::uuid, $2, NOW(), NOW(), NOW())",
      [uuid(user_id), "migration-#{user_id}@example.com"]
    )

    MigrationRepo.query!(
      "INSERT INTO organizations (id, name, slug, kind, personal_owner_id, inserted_at, updated_at) VALUES ($1::uuid, 'Personal', $2, 'personal', $3::uuid, NOW(), NOW())",
      [uuid(organization_id), "personal-#{organization_id}", uuid(user_id)]
    )

    MigrationRepo.query!(
      "INSERT INTO workspaces (id, organization_id, created_by_id, name, slug, visibility, external_sharing_policy, is_default, inserted_at, updated_at) VALUES ($1::uuid, $2::uuid, $3::uuid, 'Personal', 'default', 'open', 'public', TRUE, NOW(), NOW())",
      [uuid(workspace_id), uuid(organization_id), uuid(user_id)]
    )

    MigrationRepo.query!(
      "INSERT INTO pastes (id, data, size_bytes, visibility, workspace_id, created_by_user_id, inserted_at, updated_at) VALUES ($1::uuid, 'legacy inline content', NULL, 'public', $2::uuid, $3::uuid, NOW(), NOW())",
      [uuid(paste_id), uuid(workspace_id), uuid(user_id)]
    )

    paste_id
  end

  defp index_definition(name) do
    %{rows: [[definition]]} =
      MigrationRepo.query!("SELECT indexdef FROM pg_indexes WHERE indexname = $1", [name])

    definition
  end

  defp admin_config do
    Textbin.Repo.config()
    |> Keyword.take([:hostname, :port, :username, :password])
    |> Keyword.put(:database, "postgres")
  end

  defp repo_config(database) do
    Textbin.Repo.config()
    |> Keyword.drop([:name, :pool, :pool_size, :database])
    |> Keyword.put(:database, database)
    |> Keyword.put(:pool_size, 2)
  end

  defp restore_repo_config(nil), do: Application.delete_env(:textbin, MigrationRepo)
  defp restore_repo_config(config), do: Application.put_env(:textbin, MigrationRepo, config)

  defp uuid(id), do: Ecto.UUID.dump!(id)
end
