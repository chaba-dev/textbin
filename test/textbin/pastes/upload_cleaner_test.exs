defmodule Textbin.Pastes.UploadCleanerTest do
  use Textbin.DataCase, async: false

  import ExUnit.CaptureLog

  alias Textbin.Pastes
  alias Textbin.Pastes.Paste
  alias Textbin.Pastes.PendingUpload
  alias Textbin.Pastes.UploadCleaner
  alias Textbin.Repo
  alias Textbin.Storage

  import Textbin.AccountsFixtures

  setup do
    original_config = Application.fetch_env!(:textbin, Storage)
    original_inline_paste_bytes = Application.fetch_env!(:textbin, :inline_paste_bytes)
    root = Path.join(System.tmp_dir!(), "textbin-upload-cleaner-#{Ecto.UUID.generate()}")

    Application.put_env(:textbin, Storage,
      adapter: Textbin.Storage.Local,
      opts: [root: root]
    )

    Application.put_env(:textbin, :inline_paste_bytes, 0)

    on_exit(fn ->
      Application.put_env(:textbin, Storage, original_config)
      Application.put_env(:textbin, :inline_paste_bytes, original_inline_paste_bytes)
      File.rm_rf!(root)
    end)

    %{root: root, scope: user_scope_fixture()}
  end

  test "cleans a journaled object that has no paste row" do
    storage_key = "pastes/#{Ecto.UUID.generate()}"
    assert {:ok, _metadata} = Storage.put(storage_key, "orphaned")
    Repo.insert!(%PendingUpload{storage_key: storage_key})

    assert UploadCleaner.clean_pending_uploads(cutoff: DateTime.utc_now(), limit: 10) == 1
    assert Storage.get(storage_key) == {:error, :enoent}
    refute Repo.get(PendingUpload, storage_key)
  end

  test "successful blob creation removes its pending-upload journal", %{scope: scope} do
    assert {:ok, paste} = Pastes.create_paste(scope, %{data: "stored"})

    refute Repo.get(PendingUpload, paste.storage_key)
  end

  test "cleans only the journal when a paste row was committed", %{scope: scope} do
    assert {:ok, paste} = Pastes.create_paste(scope, %{data: "committed"})
    Repo.insert!(%PendingUpload{storage_key: paste.storage_key})

    assert UploadCleaner.clean_pending_uploads(cutoff: DateTime.utc_now(), limit: 10) == 1
    assert Storage.get(paste.storage_key) == {:ok, "committed"}
    refute Repo.get(PendingUpload, paste.storage_key)
  end

  test "failed blob creation retains a durable cleanup journal", %{root: root, scope: scope} do
    File.rm_rf!(root)
    File.write!(root, "not a directory")

    capture_log(fn ->
      assert {:error, _changeset} = Pastes.create_paste(scope, %{data: "not stored"})
    end)

    assert Repo.aggregate(PendingUpload, :count) == 1
  end

  test "a cleaner claim prevents committing a paste that would lose its object", %{scope: scope} do
    Application.put_env(:textbin, Storage,
      adapter: Textbin.ClaimingStorage,
      opts: [test_pid: self()]
    )

    assert {:error, changeset} = Pastes.create_paste(scope, %{data: "raced upload"})
    assert %{data: ["could not be finalized"]} = errors_on(changeset)
    assert Repo.aggregate(Paste, :count) == 0
    assert_receive {:cleaned_during_put, 1}
    assert_receive {:storage_delete, _storage_key}
  end

  test "sweeps only stale regular upload spool files", %{root: root} do
    upload_tmp_dir = Path.join(root, "uploads")
    File.mkdir_p!(upload_tmp_dir)
    stale = Path.join(upload_tmp_dir, "textbin-upload-stale")
    fresh = Path.join(upload_tmp_dir, "textbin-upload-fresh")
    unrelated = Path.join(upload_tmp_dir, "other-file")
    File.write!(stale, "stale")
    File.write!(fresh, "fresh")
    File.write!(unrelated, "unrelated")
    File.touch!(stale, 1_000)
    File.touch!(fresh, 2_000)

    assert UploadCleaner.sweep_spool_files(upload_tmp_dir, cutoff: 1_500) == 1
    refute File.exists?(stale)
    assert File.exists?(fresh)
    assert File.exists?(unrelated)
  end

  test "does not sweep a stale spool owned by a live request", %{root: root} do
    upload_tmp_dir = Path.join(root, "uploads")
    path = Path.join(upload_tmp_dir, "textbin-upload-active")
    File.mkdir_p!(upload_tmp_dir)
    File.write!(path, "active")
    File.touch!(path, 1_000)
    UploadCleaner.register_spool(path)

    assert UploadCleaner.sweep_spool_files(upload_tmp_dir, cutoff: 1_500) == 0
    assert File.exists?(path)

    UploadCleaner.unregister_spool(path)
    assert UploadCleaner.sweep_spool_files(upload_tmp_dir, cutoff: 1_500) == 1
    refute File.exists?(path)
  end
end
