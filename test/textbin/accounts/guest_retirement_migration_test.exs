defmodule Textbin.Accounts.GuestRetirementMigrationTest do
  use ExUnit.Case, async: false

  alias Textbin.MigrationRepo

  @before_retirement 20_261_011_100_000
  @retirement 20_261_011_110_000

  test "hides guest content, schedules it for purging and leaves accounts alone" do
    database = "textbin_guest_migration_#{Ecto.UUID.generate()}"
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
    Ecto.Migrator.run(MigrationRepo, migrations, :up, to: @before_retirement, log: false)

    guest = insert_account("guest")
    registered = insert_account("registered")

    Ecto.Migrator.run(MigrationRepo, migrations, :up, to: @retirement, log: false)

    assert deletion_requested?("workspaces", guest.workspace_id)
    assert deletion_requested?("organizations", guest.organization_id)
    assert expired?(guest.paste_id)
    assert token_count(guest.user_id) == 0

    refute deletion_requested?("workspaces", registered.workspace_id)
    refute deletion_requested?("organizations", registered.organization_id)
    refute expired?(registered.paste_id)
    assert token_count(registered.user_id) == 1
  end

  defp insert_account(kind) do
    ids = %{
      user_id: Ecto.UUID.generate(),
      organization_id: Ecto.UUID.generate(),
      workspace_id: Ecto.UUID.generate(),
      paste_id: Ecto.UUID.generate()
    }

    MigrationRepo.query!(
      "INSERT INTO users (id, email, kind, inserted_at, updated_at) VALUES ($1::uuid, $2, $3, NOW(), NOW())",
      [uuid(ids.user_id), "#{kind}-#{ids.user_id}@example.com", kind]
    )

    MigrationRepo.query!(
      "INSERT INTO users_tokens (id, user_id, token, context, inserted_at) VALUES ($1::uuid, $2::uuid, $3, 'session', NOW())",
      [uuid(Ecto.UUID.generate()), uuid(ids.user_id), :crypto.strong_rand_bytes(32)]
    )

    MigrationRepo.query!(
      "INSERT INTO organizations (id, name, slug, kind, personal_owner_id, inserted_at, updated_at) VALUES ($1::uuid, 'Personal', $2, 'personal', $3::uuid, NOW(), NOW())",
      [uuid(ids.organization_id), "personal-#{ids.organization_id}", uuid(ids.user_id)]
    )

    MigrationRepo.query!(
      "INSERT INTO workspaces (id, organization_id, created_by_id, name, slug, visibility, external_sharing_policy, is_default, inserted_at, updated_at) VALUES ($1::uuid, $2::uuid, $3::uuid, 'Default', 'default', 'open', 'unlisted', TRUE, NOW(), NOW())",
      [uuid(ids.workspace_id), uuid(ids.organization_id), uuid(ids.user_id)]
    )

    MigrationRepo.query!(
      "INSERT INTO pastes (id, data, visibility, workspace_id, created_by_user_id, inserted_at, updated_at) VALUES ($1::uuid, 'content', 'unlisted', $2::uuid, $3::uuid, NOW(), NOW())",
      [uuid(ids.paste_id), uuid(ids.workspace_id), uuid(ids.user_id)]
    )

    ids
  end

  defp deletion_requested?(table, id) do
    %{rows: [[requested_at]]} =
      MigrationRepo.query!("SELECT deletion_requested_at FROM #{table} WHERE id = $1::uuid", [
        uuid(id)
      ])

    not is_nil(requested_at)
  end

  defp expired?(paste_id) do
    %{rows: [[expired?]]} =
      MigrationRepo.query!(
        "SELECT expires_at IS NOT NULL AND expires_at <= NOW() FROM pastes WHERE id = $1::uuid",
        [uuid(paste_id)]
      )

    expired?
  end

  defp token_count(user_id) do
    %{rows: [[count]]} =
      MigrationRepo.query!("SELECT count(*) FROM users_tokens WHERE user_id = $1::uuid", [
        uuid(user_id)
      ])

    count
  end

  # The admin connection mirrors the repository's endpoint, which is a Unix
  # socket in development and test and a host/port pair in CI.
  defp admin_config do
    Textbin.Repo.config()
    |> Keyword.take([:hostname, :port, :socket_dir, :username, :password])
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
