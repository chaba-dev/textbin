defmodule Textbin.FailingDeleteStorage do
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
    send(Keyword.fetch!(opts, :test_pid), {:storage_delete_failed, storage_key})
    {:error, :unavailable}
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
