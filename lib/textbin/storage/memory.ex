defmodule Textbin.Storage.Memory do
  @moduledoc false

  use Agent

  @behaviour Textbin.Storage

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @impl true
  def put(storage_key, data, _opts) when is_binary(data) do
    Agent.update(__MODULE__, &Map.put(&1, storage_key, data))
    {:ok, %{size_bytes: byte_size(data), sha256: :crypto.hash(:sha256, data)}}
  end

  @impl true
  def put_file(storage_key, path, metadata, _opts) do
    with {:ok, data} <- File.read(path) do
      Agent.update(__MODULE__, &Map.put(&1, storage_key, data))
      {:ok, metadata}
    end
  end

  @impl true
  def get(storage_key, _opts) do
    Agent.get(__MODULE__, fn objects ->
      case Map.fetch(objects, storage_key) do
        {:ok, data} -> {:ok, data}
        :error -> {:error, :enoent}
      end
    end)
  end

  @impl true
  def delete(storage_key, _opts) do
    Agent.update(__MODULE__, &Map.delete(&1, storage_key))
  end
end
