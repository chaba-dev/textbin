defmodule Textbin.BlockingStorage do
  @moduledoc false

  @behaviour Textbin.Storage

  @impl true
  def put(storage_key, data, opts), do: delegate(opts, :put, [storage_key, data])

  @impl true
  def put_file(storage_key, path, metadata, opts) do
    delegate(opts, :put_file, [storage_key, path, metadata])
  end

  @impl true
  def get(storage_key, opts), do: delegate(opts, :get, [storage_key])

  @impl true
  def delete(storage_key, opts) do
    gate = Keyword.fetch!(opts, :gate)

    if Agent.get_and_update(gate, fn block? -> {block?, false} end) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:storage_delete_blocked, self(), storage_key})

      receive do
        {:continue_storage_delete, ^storage_key} -> :ok
      after
        1_000 ->
          raise "timed out waiting to continue blocked storage delete for #{storage_key}"
      end
    end

    delegate(opts, :delete, [storage_key])
  end

  defp delegate(opts, function, args) do
    config = Keyword.fetch!(opts, :delegate)
    adapter = Keyword.fetch!(config, :adapter)

    adapter_opts =
      case Keyword.get(config, :opts, []) do
        {:replace, adapter_opts} -> adapter_opts
        adapter_opts -> adapter_opts
      end

    apply(adapter, function, args ++ [adapter_opts])
  end
end
