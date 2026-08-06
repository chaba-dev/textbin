defmodule Textbin.Storage.Local do
  @moduledoc """
  Stores paste bodies on a local filesystem using atomic same-filesystem renames.
  """

  @behaviour Textbin.Storage

  @impl true
  def put(storage_key, data, opts) when is_binary(data) do
    with {:ok, destination} <- storage_path(storage_key, opts),
         :ok <- prepare_directory(Path.dirname(destination), opts) do
      finalize_put(destination, data, opts)
    end
  end

  @impl true
  def put_file(storage_key, source, metadata, opts) do
    with {:ok, destination} <- storage_path(storage_key, opts),
         :ok <- prepare_directory(Path.dirname(destination), opts) do
      finalize_file(destination, source, metadata, opts)
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
      durable_remove(path, opts)
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

  defp finalize_put(destination, data, opts) do
    temporary = temporary_path(destination)

    try do
      with :ok <- write_temporary(temporary, data),
           :ok <- File.rename(temporary, destination),
           :ok <- sync_directory(Path.dirname(destination), opts) do
        {:ok, metadata(data)}
      end
    after
      durable_remove!(temporary, opts)
    end
  end

  defp finalize_file(destination, source, metadata, opts) do
    temporary = temporary_path(destination)

    try do
      with {:ok, _bytes_copied} <- File.copy(source, temporary),
           :ok <- File.chmod(temporary, 0o600),
           :ok <- sync_file(temporary),
           stored_metadata <-
             Textbin.Storage.calculate_metadata(File.stream!(temporary, 64_000, [])),
           :ok <- verify_metadata(stored_metadata, metadata),
           :ok <- File.rename(temporary, destination),
           :ok <- sync_directory(Path.dirname(destination), opts) do
        {:ok, stored_metadata}
      else
        {:error, reason} -> {:error, reason}
      end
    after
      durable_remove!(temporary, opts)
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
    with :ok <- :file.write(file, data) do
      :file.sync(file)
    end
  end

  defp sync_file(path) do
    case File.open(path, [:append, :binary], &:file.sync/1) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_directory(path, opts) do
    with :ok <- ensure_directory(path, opts) do
      File.chmod(path, 0o700)
    end
  end

  defp ensure_directory(path, opts) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        :ok

      {:ok, _stat} ->
        {:error, :enotdir}

      {:error, :enoent} ->
        parent = Path.dirname(path)

        with :ok <- ensure_directory(parent, opts),
             :ok <- mkdir(path),
             :ok <- File.chmod(path, 0o700),
             :ok <- sync_directory(parent, opts) do
          sync_directory(path, opts)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mkdir(path) do
    case File.mkdir(path) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_directory(path, opts) do
    case Keyword.get(opts, :sync_directory) do
      sync when is_function(sync, 1) ->
        sync.(path)

      nil ->
        case File.open(path, [:read, :directory], &:file.sync/1) do
          {:ok, result} -> result
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp durable_remove(path, opts) do
    case File.rm(path) do
      :ok -> sync_directory(Path.dirname(path), opts)
      {:error, :enoent} -> sync_parent_if_present(path, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_parent_if_present(path, opts) do
    case File.lstat(Path.dirname(path)) do
      {:ok, %{type: :directory}} -> sync_directory(Path.dirname(path), opts)
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :enotdir}
      {:error, reason} -> {:error, reason}
    end
  end

  defp durable_remove!(path, opts) do
    case durable_remove(path, opts) do
      :ok -> :ok
      {:error, reason} -> raise "could not durably remove temporary file: #{inspect(reason)}"
    end
  end

  defp verify_metadata(metadata, metadata), do: :ok
  defp verify_metadata(_stored_metadata, _expected_metadata), do: {:error, :metadata_mismatch}
end
