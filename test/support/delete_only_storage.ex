defmodule Textbin.DeleteOnlyStorage do
  @moduledoc false

  @behaviour Textbin.Storage

  alias Textbin.Storage.Memory

  @impl true
  def put(storage_key, data, _opts), do: Memory.put(storage_key, data, [])

  @impl true
  def put_file(storage_key, path, metadata, _opts) do
    Memory.put_file(storage_key, path, metadata, [])
  end

  @impl true
  def get(storage_key, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:unexpected_storage_get, storage_key})
    {:error, :read_unavailable}
  end

  @impl true
  def delete(storage_key, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:storage_deleted, storage_key})
    Memory.delete(storage_key, [])
  end
end
