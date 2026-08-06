defmodule Textbin.Pastes.UploadCleaner do
  @moduledoc """
  Recovers stale request spools and journaled blob uploads after interrupted
  request processes or host restarts.
  """

  use GenServer

  import Ecto.Query, warn: false

  alias Textbin.Pastes.Paste
  alias Textbin.Pastes.PendingUpload
  alias Textbin.Repo
  alias Textbin.Storage

  require Logger

  @active_spools_table :textbin_active_upload_spools
  @default_interval_ms :timer.minutes(15)
  @default_stale_after_seconds :timer.hours(1) |> div(1_000)
  @default_batch_size 500

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def run_now(server \\ __MODULE__), do: GenServer.call(server, :run_now)

  def register_spool(path) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:register_spool, path})
    :ok
  end

  def unregister_spool(path) do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, {:unregister_spool, path})
    :ok
  end

  def clean_pending_uploads(opts \\ []) do
    cutoff = Keyword.get_lazy(opts, :cutoff, &default_cutoff/0)
    limit = Keyword.get(opts, :limit, @default_batch_size)

    Repo.all(
      from upload in PendingUpload,
        where:
          upload.inserted_at <= ^cutoff and
            (is_nil(upload.claimed_at) or upload.claimed_at <= ^cutoff),
        order_by: [asc: upload.inserted_at],
        limit: ^limit
    )
    |> Enum.count(&claim_and_clean_pending_upload(&1, cutoff))
  end

  def sweep_spool_files(path, opts \\ []) do
    cutoff = Keyword.get_lazy(opts, :cutoff, &default_spool_cutoff/0)

    path
    |> Path.join("textbin-upload-*")
    |> Path.wildcard()
    |> Enum.count(&remove_stale_spool(&1, cutoff))
  end

  @impl true
  def init(opts) do
    :ets.new(@active_spools_table, [:named_table, :protected, :set])

    state = %{
      interval_ms:
        Keyword.get(
          opts,
          :interval_ms,
          Application.get_env(:textbin, :upload_cleanup_interval_ms, @default_interval_ms)
        ),
      stale_after_seconds:
        Keyword.get(
          opts,
          :stale_after_seconds,
          Application.get_env(
            :textbin,
            :upload_cleanup_stale_after_seconds,
            @default_stale_after_seconds
          )
        ),
      batch_size: Keyword.get(opts, :batch_size, @default_batch_size),
      upload_tmp_dir:
        Keyword.get(
          opts,
          :upload_tmp_dir,
          Application.get_env(:textbin, :upload_tmp_dir, System.tmp_dir!())
        )
    }

    {:ok, schedule(state, Keyword.get(opts, :initial_delay_ms, 0))}
  end

  @impl true
  def handle_call(:run_now, _from, state), do: {:reply, clean(state), state}

  def handle_call({:register_spool, path}, {owner, _tag}, state) do
    :ets.insert(@active_spools_table, {path, owner})
    {:reply, :ok, state}
  end

  def handle_call({:unregister_spool, path}, _from, state) do
    :ets.delete(@active_spools_table, path)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    clean(state)
    {:noreply, schedule(state, state.interval_ms)}
  end

  defp clean(state) do
    cutoff = DateTime.add(DateTime.utc_now(), -state.stale_after_seconds, :second)
    spool_cutoff = DateTime.to_unix(cutoff)

    %{
      pending_uploads: clean_pending_uploads(cutoff: cutoff, limit: state.batch_size),
      spool_files: sweep_spool_files(state.upload_tmp_dir, cutoff: spool_cutoff)
    }
  rescue
    exception ->
      Logger.error("Failed to clean interrupted uploads: #{Exception.message(exception)}")
      :error
  end

  defp claim_and_clean_pending_upload(%PendingUpload{} = upload, claim_cutoff) do
    claimed_at = DateTime.utc_now()

    {claimed_count, nil} =
      Repo.update_all(
        from(candidate in PendingUpload,
          where:
            candidate.storage_key == ^upload.storage_key and
              candidate.inserted_at <= ^claim_cutoff and
              (is_nil(candidate.claimed_at) or candidate.claimed_at <= ^claim_cutoff)
        ),
        set: [claimed_at: claimed_at]
      )

    claimed_count == 1 and clean_claimed_upload(%{upload | claimed_at: claimed_at})
  end

  defp clean_claimed_upload(%PendingUpload{} = upload) do
    if Repo.exists?(from paste in Paste, where: paste.storage_key == ^upload.storage_key) do
      delete_pending_upload(upload)
    else
      case Storage.delete(upload.storage_key) do
        :ok ->
          delete_pending_upload(upload)

        {:error, reason} ->
          Logger.error(
            "Failed to delete interrupted upload #{upload.storage_key}: #{inspect(reason)}"
          )

          Repo.update_all(
            from(candidate in PendingUpload,
              where:
                candidate.storage_key == ^upload.storage_key and
                  candidate.claimed_at == ^upload.claimed_at
            ),
            set: [claimed_at: nil]
          )

          false
      end
    end
  end

  defp delete_pending_upload(upload) do
    Repo.delete_all(
      from candidate in PendingUpload,
        where:
          candidate.storage_key == ^upload.storage_key and
            candidate.claimed_at == ^upload.claimed_at
    )

    true
  end

  defp remove_stale_spool(path, cutoff) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :regular, mtime: mtime}} when mtime <= cutoff ->
        !active_spool?(path) and File.rm(path) == :ok

      _result ->
        false
    end
  end

  defp active_spool?(path) do
    case :ets.lookup(@active_spools_table, path) do
      [{^path, owner}] ->
        if Process.alive?(owner) do
          true
        else
          :ets.delete(@active_spools_table, path)
          false
        end

      [] ->
        false
    end
  rescue
    ArgumentError -> false
  end

  defp default_cutoff do
    DateTime.add(DateTime.utc_now(), -@default_stale_after_seconds, :second)
  end

  defp default_spool_cutoff,
    do: DateTime.utc_now() |> DateTime.to_unix() |> Kernel.-(@default_stale_after_seconds)

  defp schedule(state, delay_ms) do
    Process.send_after(self(), :cleanup, delay_ms)
    state
  end
end
