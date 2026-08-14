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
  def get(storage_key, opts) do
    block_once(opts, :read_gate, {:storage_read_blocked, self(), storage_key}, fn
      {:continue_storage_read, ^storage_key} -> :ok
    end)

    delegate(opts, :get, [storage_key])
  end

  @impl true
  def delete(storage_key, opts) do
    block_once(opts, :gate, {:storage_delete_blocked, self(), storage_key}, fn
      {:continue_storage_delete, ^storage_key} -> :ok
    end)

    delegate(opts, :delete, [storage_key])
  end

  defp block_once(opts, gate_key, message, continuation) do
    gate = Keyword.get(opts, gate_key)

    if gate && Agent.get_and_update(gate, fn block? -> {block?, false} end) do
      await_continuation(opts, message, continuation)
    end
  end

  defp await_continuation(opts, message, continuation) do
    send(Keyword.fetch!(opts, :test_pid), message)

    receive do
      message -> continuation.(message)
    after
      1_000 -> raise "timed out waiting for blocked storage operation"
    end
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
