defmodule Textbin.BlockingStorage do
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
  def get(storage_key, _opts), do: Memory.get(storage_key, [])

  @impl true
  def delete(storage_key, opts) do
    gate = Keyword.fetch!(opts, :gate)

    if Agent.get_and_update(gate, fn block? -> {block?, false} end) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:storage_delete_blocked, self(), storage_key})

      receive do
        {:continue_storage_delete, ^storage_key} -> :ok
      end
    end

    Memory.delete(storage_key, [])
  end
end
