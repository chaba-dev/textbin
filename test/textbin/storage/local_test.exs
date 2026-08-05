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

  test "rejects storage keys that could escape the configured root", %{opts: opts, root: root} do
    assert Local.put("../outside", "unsafe", opts) == {:error, :invalid_storage_key}
    refute File.exists?(Path.join(Path.dirname(root), "outside"))
  end
end
