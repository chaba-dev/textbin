defmodule Textbin.ClaimingStorage do
  @moduledoc false

  @behaviour Textbin.Storage

  alias Textbin.Pastes.UploadCleaner

  @impl true
  def put(_storage_key, data, opts) do
    claim_pending_upload(opts)
    {:ok, metadata(data)}
  end

  @impl true
  def put_file(_storage_key, path, _expected_metadata, opts) do
    data = File.read!(path)
    claim_pending_upload(opts)
    {:ok, metadata(data)}
  end

  @impl true
  def get(_storage_key, _opts), do: {:error, :enoent}

  @impl true
  def delete(storage_key, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:storage_delete, storage_key})
    :ok
  end

  defp claim_pending_upload(opts) do
    cleaned =
      UploadCleaner.clean_pending_uploads(
        cutoff: DateTime.add(DateTime.utc_now(), 1, :second),
        limit: 1
      )

    send(Keyword.fetch!(opts, :test_pid), {:cleaned_during_put, cleaned})
  end

  defp metadata(data) do
    %{size_bytes: byte_size(data), sha256: :crypto.hash(:sha256, data)}
  end
end
