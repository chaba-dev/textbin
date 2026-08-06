defmodule Textbin.Storage.LocalTest do
  use ExUnit.Case, async: true

  alias Textbin.Storage.Local

  setup do
    root = Path.join(System.tmp_dir!(), "textbin-storage-#{Ecto.UUID.generate()}")
    on_exit(fn -> File.rm_rf!(root) end)
    %{opts: [root: root], root: root}
  end

  test "writes, reads, and deletes content", %{opts: opts} do
    data = "stored locally\n"

    assert {:ok, metadata} = Local.put("pastes/one", data, opts)
    assert metadata.size_bytes == byte_size(data)
    assert metadata.sha256 == :crypto.hash(:sha256, data)
    assert Local.get("pastes/one", opts) == {:ok, data}

    assert :ok = Local.delete("pastes/one", opts)
    assert Local.get("pastes/one", opts) == {:error, :enoent}
    assert :ok = Local.delete("pastes/one", opts)
  end

  test "copies a file into storage without consuming the source", %{opts: opts, root: root} do
    data = String.duplicate("streamed locally\n", 8_000)
    source = Path.join(root, "upload")
    metadata = %{size_bytes: byte_size(data), sha256: :crypto.hash(:sha256, data)}
    File.mkdir_p!(root)
    File.write!(source, data)

    assert Local.put_file("pastes/file", source, metadata, opts) == {:ok, metadata}
    assert Local.get("pastes/file", opts) == {:ok, data}
    assert File.read!(source) == data

    assert {:ok, %{mode: mode}} = File.stat(Path.join(root, "pastes/file"))
    assert Bitwise.band(mode, 0o777) == 0o600
    assert Path.wildcard(Path.join(root, "pastes/file.tmp-*")) == []
  end

  test "rejects file metadata that does not match copied content", %{opts: opts, root: root} do
    source = Path.join(System.tmp_dir!(), "textbin-local-upload-#{Ecto.UUID.generate()}")
    data = "same-size metadata mismatch"
    metadata = %{size_bytes: byte_size(data), sha256: :crypto.hash(:sha256, "x" <> data)}
    File.write!(source, data)
    on_exit(fn -> File.rm(source) end)

    assert Local.put_file("pastes/mismatch", source, metadata, opts) ==
             {:error, :metadata_mismatch}

    assert Local.get("pastes/mismatch", opts) == {:error, :enoent}
    assert Path.wildcard(Path.join(root, "pastes/mismatch.tmp-*")) == []
  end

  test "stores paste objects with private permissions", %{opts: opts, root: root} do
    assert {:ok, _metadata} = Local.put("pastes/private", "private data", opts)

    assert {:ok, %{mode: mode}} = File.stat(Path.join(root, "pastes/private"))
    assert Bitwise.band(mode, 0o777) == 0o600
  end

  test "rejects storage keys that could escape the configured root", %{opts: opts, root: root} do
    assert Local.put("../outside", "unsafe", opts) == {:error, :invalid_storage_key}
    refute File.exists?(Path.join(Path.dirname(root), "outside"))
  end
end
