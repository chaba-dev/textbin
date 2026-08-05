defmodule Textbin.Storage.Local do
  @moduledoc """
  Stores paste bodies on a local filesystem using atomic same-filesystem renames.
  """

  @behaviour Textbin.Storage

  @impl true
  def put(storage_key, data, opts) when is_binary(data) do
    with {:ok, destination} <- storage_path(storage_key, opts),
         :ok <- File.mkdir_p(Path.dirname(destination)) do
      temporary =
        destination <> ".tmp-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

      case write_temporary(temporary, data) do
        :ok ->
          case File.rename(temporary, destination) do
            :ok -> {:ok, metadata(data)}
            {:error, reason} -> cleanup_error(temporary, reason)
          end

        {:error, reason} ->
          cleanup_error(temporary, reason)
      end
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

  defp write_temporary(path, data) do
    case File.open(path, [:write, :binary, :exclusive], fn file ->
           with :ok <- IO.binwrite(file, data),
                :ok <- :file.sync(file) do
             :ok
           end
         end) do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_error(temporary, reason) do
    File.rm(temporary)
    {:error, reason}
  end
end
