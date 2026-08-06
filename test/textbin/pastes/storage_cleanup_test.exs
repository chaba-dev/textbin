defmodule Textbin.Pastes.StorageCleanupTest do
  use Textbin.DataCase, async: false

  import ExUnit.CaptureLog
  import Textbin.AccountsFixtures

  alias Textbin.Pastes
  alias Textbin.Pastes.Paste
  alias Textbin.Repo
  alias Textbin.Storage

  setup do
    original_config = Application.fetch_env!(:textbin, Storage)
    original_inline_paste_bytes = Application.fetch_env!(:textbin, :inline_paste_bytes)
    root = Path.join(System.tmp_dir!(), "textbin-cleanup-#{Ecto.UUID.generate()}")
    blocked_root = root <> "-blocked"

    Application.put_env(:textbin, Storage,
      adapter: Textbin.Storage.Local,
      opts: [root: root]
    )

    Application.put_env(:textbin, :inline_paste_bytes, 0)

    on_exit(fn ->
      Application.put_env(:textbin, Storage, original_config)
      Application.put_env(:textbin, :inline_paste_bytes, original_inline_paste_bytes)
      File.rm_rf!(root)
      File.rm_rf!(blocked_root)
    end)

    scope = user_scope_fixture()
    %{scope: scope, root: root, blocked_root: blocked_root}
  end

  test "expiration cleanup retains metadata until object deletion succeeds", context do
    {:ok, paste} = Pastes.create_paste(context.scope, %{data: "retry cleanup"})
    expire!(paste)
    block_storage_deletes!(context.blocked_root)

    log = capture_log(fn -> assert Pastes.delete_expired_pastes(limit: 1) == 0 end)
    assert log =~ "Failed to delete stored paste content: :enotdir"
    assert Repo.get(Paste, paste.id)

    use_storage_root(context.root)

    assert Pastes.delete_expired_pastes(limit: 1) == 1
    refute Repo.get(Paste, paste.id)
    assert Storage.get(paste.storage_key) == {:error, :enoent}
  end

  test "manual deletion leaves an invisible tombstone when storage is unavailable", context do
    {:ok, paste} = Pastes.create_paste(context.scope, %{data: "retry manual deletion"})
    block_storage_deletes!(context.blocked_root)

    log =
      capture_log(fn ->
        assert {:error, :enotdir} = Pastes.delete_paste(context.scope, paste)
      end)

    assert log =~ "Failed to delete stored paste content: :enotdir"
    refute Pastes.get_paste(context.scope, paste.id)
    assert Repo.get(Paste, paste.id)

    use_storage_root(context.root)
    assert Pastes.delete_expired_pastes(limit: 1) == 1
    refute Repo.get(Paste, paste.id)
  end

  test "blob reads reject same-size content with the wrong checksum", context do
    {:ok, paste} = Pastes.create_paste(context.scope, %{data: "original content"})
    File.write!(Path.join(context.root, paste.storage_key), "corrupted bytes!")

    assert_raise Textbin.Storage.IntegrityError, ~r/integrity check failed/, fn ->
      Pastes.get_paste!(context.scope, paste.id)
    end
  end

  defp expire!(paste) do
    paste
    |> Ecto.Changeset.change(expires_at: DateTime.add(Paste.utc_now_ms(), -1, :second))
    |> Repo.update!()
  end

  defp block_storage_deletes!(blocked_root) do
    File.write!(blocked_root, "not a directory")
    use_storage_root(blocked_root)
  end

  defp use_storage_root(root) do
    Application.put_env(:textbin, Storage,
      adapter: Textbin.Storage.Local,
      opts: [root: root]
    )
  end
end
