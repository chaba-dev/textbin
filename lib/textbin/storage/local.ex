defmodule Textbin.Storage.Local do
  @moduledoc """
  Stores paste bodies on a local filesystem using atomic same-filesystem renames.
  """

  @behaviour Textbin.Storage

  @impl true
  def put(storage_key, data, opts) when is_binary(data) do
    with {:ok, destination} <- storage_path(storage_key, opts),
         :ok <- prepare_directory(Path.dirname(destination)) do
      finalize_put(destination, data)
    end
  end

  @impl true
  def put_file(storage_key, source, metadata, opts) do
    with {:ok, destination} <- storage_path(storage_key, opts),
         :ok <- prepare_directory(Path.dirname(destination)) do
      finalize_file(destination, source, metadata)
    end
  end

  @impl true
  def get(storage_key, opts) do
    with {:ok, path} <- storage_path(storage_key, opts) do
      File.read(path)
    end
  end

  @impl true
  def delete(storage_key, opts) do
    with {:ok, path} <- storage_path(storage_key, opts) do
      case File.rm(path) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp storage_path(storage_key, opts) do
    root = opts |> Keyword.fetch!(:root) |> Path.expand()
    segments = String.split(storage_key, "/")

    if valid_segments?(segments) do
      {:ok, Path.join([root | segments])}
    else
      {:error, :invalid_storage_key}
    end
  end

  defp valid_segments?(segments) do
    segments != [] and
      Enum.all?(segments, fn segment ->
        segment not in ["", ".", ".."] and String.match?(segment, ~r/^[A-Za-z0-9._-]+$/)
      end)
  end

  defp metadata(data) do
    %{size_bytes: byte_size(data), sha256: :crypto.hash(:sha256, data)}
  end

  defp finalize_put(destination, data) do
    temporary =
      destination <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    with :ok <- write_temporary(temporary, data),
         :ok <- File.rename(temporary, destination) do
      {:ok, metadata(data)}
    else
      {:error, reason} -> cleanup_error(temporary, reason)
    end
  end

  defp finalize_file(destination, source, metadata) do
    temporary = temporary_path(destination)

    try do
      with {:ok, _bytes_copied} <- File.copy(source, temporary),
           :ok <- File.chmod(temporary, 0o600),
           :ok <- sync_file(temporary),
           stored_metadata <-
             Textbin.Storage.calculate_metadata(File.stream!(temporary, 64_000, [])),
           :ok <- verify_metadata(stored_metadata, metadata),
           :ok <- File.rename(temporary, destination) do
        {:ok, stored_metadata}
      else
        {:error, reason} -> {:error, reason}
      end
    after
      File.rm(temporary)
    end
  end

  defp temporary_path(destination) do
    destination <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp write_temporary(path, data) do
    case File.open(path, [:write, :binary, :exclusive], &write_private_file(&1, path, data)) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_private_file(file, path, data) do
    with :ok <- File.chmod(path, 0o600) do
      write_and_sync(file, data)
    end
  end

  defp write_and_sync(file, data) do
    IO.binwrite(file, data)
    :file.sync(file)
  end

  defp sync_file(path) do
    case File.open(path, [:append, :binary], &:file.sync/1) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_error(temporary, reason) do
    File.rm(temporary)
    {:error, reason}
  end

  defp prepare_directory(path) do
    with :ok <- File.mkdir_p(path) do
      File.chmod(path, 0o700)
    end
  end

  defp verify_metadata(metadata, metadata), do: :ok
  defp verify_metadata(_stored_metadata, _expected_metadata), do: {:error, :metadata_mismatch}
end
