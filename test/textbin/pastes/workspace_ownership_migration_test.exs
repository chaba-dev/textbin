defmodule Textbin.Pastes.WorkspaceOwnershipMigrationTest do
  use ExUnit.Case, async: false

  alias Textbin.MigrationRepo

  @before_organizations_version 20_260_806_100_000
  @organizations_version 20_260_810_090_000
  @ownership_version 20_260_810_120_000

  test "backfills workspace ownership, restores personal ownership, and rejects team rollback" do
    database = "textbin_migration_#{Ecto.UUID.generate()}"
    {:ok, admin} = Postgrex.start_link(admin_config())
    Process.unlink(admin)
    Postgrex.query!(admin, ~s(CREATE DATABASE "#{database}"), [])

    on_exit(fn ->
      Postgrex.query!(admin, "DROP DATABASE IF EXISTS \"#{database}\" WITH (FORCE)", [])
      if Process.alive?(admin), do: GenServer.stop(admin)
    end)

    {:ok, repo} = MigrationRepo.start_link(repo_config(database))
    Process.unlink(repo)
    on_exit(fn -> if Process.alive?(repo), do: GenServer.stop(repo) end)

    migrations = Path.expand("../../../priv/repo/migrations", __DIR__)
    Ecto.Migrator.run(MigrationRepo, migrations, :up, to: @before_organizations_version)

    user_id = Ecto.UUID.generate()
    insert_user(user_id, "migration@example.com")
    legacy_paste_id = insert_legacy_paste(user_id, "before ownership migration")

    Ecto.Migrator.run(MigrationRepo, migrations, :up, to: @ownership_version)
    workspace_id = personal_workspace_id(user_id)

    assert ownership(legacy_paste_id) == {workspace_id, user_id}
    refute column_exists?("pastes", "user_id")

    workspace_paste_id = insert_workspace_paste(workspace_id, user_id, "workspace paste")
    assert ownership(workspace_paste_id) == {workspace_id, user_id}

    Ecto.Migrator.run(MigrationRepo, migrations, :down, to: @organizations_version)

    assert %{rows: rows} =
             MigrationRepo.query!(
               "SELECT id::text, data, user_id::text FROM pastes WHERE id IN ($1::uuid, $2::uuid) ORDER BY data",
               [uuid(legacy_paste_id), uuid(workspace_paste_id)]
             )

    assert rows == [
             [legacy_paste_id, "before ownership migration", user_id],
             [workspace_paste_id, "workspace paste", user_id]
           ]

    rollback_paste_id = insert_legacy_paste(user_id, "after rollback")

    Ecto.Migrator.run(MigrationRepo, migrations, :up, to: @ownership_version)
    assert ownership(rollback_paste_id) == {workspace_id, user_id}
    refute column_exists?("pastes", "user_id")

    team_workspace_id = insert_team_workspace(user_id)
    insert_workspace_paste(team_workspace_id, user_id, "team paste")

    assert_raise Postgrex.Error,
                 ~r/cannot roll back workspace paste ownership with non-personal workspace pastes/,
                 fn ->
                   Ecto.Migrator.run(MigrationRepo, migrations, :down, to: @organizations_version)
                 end
  end

  defp insert_user(id, email) do
    MigrationRepo.query!(
      "INSERT INTO users (id, email, inserted_at, updated_at) VALUES ($1::uuid, $2, NOW(), NOW())",
      [uuid(id), email]
    )
  end

  defp insert_legacy_paste(user_id, data) do
    id = Ecto.UUID.generate()

    MigrationRepo.query!(
      "INSERT INTO pastes (id, data, user_id, inserted_at, updated_at) VALUES ($1::uuid, $2, $3::uuid, NOW(), NOW())",
      [uuid(id), data, uuid(user_id)]
    )

    id
  end

  defp insert_workspace_paste(workspace_id, user_id, data) do
    id = Ecto.UUID.generate()

    MigrationRepo.query!(
      "INSERT INTO pastes (id, data, workspace_id, created_by_user_id, inserted_at, updated_at) VALUES ($1::uuid, $2, $3::uuid, $4::uuid, NOW(), NOW())",
      [uuid(id), data, uuid(workspace_id), uuid(user_id)]
    )

    id
  end

  defp ownership(paste_id) do
    %{rows: [[workspace_id, creator_id]]} =
      MigrationRepo.query!(
        "SELECT workspace_id::text, created_by_user_id::text FROM pastes WHERE id = $1::uuid",
        [uuid(paste_id)]
      )

    {workspace_id, creator_id}
  end

  defp column_exists?(table, column) do
    %{rows: [[exists?]]} =
      MigrationRepo.query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = $1 AND column_name = $2)",
        [table, column]
      )

    exists?
  end

  defp personal_workspace_id(user_id) do
    %{rows: [[workspace_id]]} =
      MigrationRepo.query!(
        "SELECT id::text FROM workspaces WHERE created_by_id = $1::uuid AND is_default",
        [uuid(user_id)]
      )

    workspace_id
  end

  defp insert_team_workspace(user_id) do
    organization_id = Ecto.UUID.generate()
    workspace_id = Ecto.UUID.generate()

    MigrationRepo.query!(
      "INSERT INTO organizations (id, name, slug, kind, inserted_at, updated_at) VALUES ($1::uuid, 'Team', $2, 'team', NOW(), NOW())",
      [uuid(organization_id), "team-#{organization_id}"]
    )

    MigrationRepo.query!(
      "INSERT INTO workspaces (id, organization_id, created_by_id, name, slug, visibility, is_default, inserted_at, updated_at) VALUES ($1::uuid, $2::uuid, $3::uuid, 'Team', 'default', 'open', TRUE, NOW(), NOW())",
      [uuid(workspace_id), uuid(organization_id), uuid(user_id)]
    )

    workspace_id
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

  defp uuid(id), do: Ecto.UUID.dump!(id)
end
