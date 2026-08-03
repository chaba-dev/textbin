defmodule Textbin.Pastes.ExpirationCleaner do
  @moduledoc """
  Periodically hard-deletes expired pastes in bounded batches.
  """

  use GenServer

  require Logger

  alias Textbin.Pastes

  @telemetry_event [:textbin, :pastes, :expiration_cleanup]
  @default_interval_ms :timer.minutes(15)
  @default_batch_size 500

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Runs one cleanup batch immediately.

  Returns the number of deleted pastes, or `:error` after a cleanup failure has
  been logged and reported through telemetry.
  """
  @spec run_now(GenServer.server()) :: non_neg_integer() | :error
  def run_now(server \\ __MODULE__) do
    GenServer.call(server, :run_now)
  end

  @impl true
  def init(opts) do
    interval_ms =
      opts
      |> Keyword.get(
        :interval_ms,
        Application.get_env(
          :textbin,
          :expiration_cleanup_interval_ms,
          @default_interval_ms
        )
      )
      |> positive_integer!(:interval_ms)

    batch_size =
      opts
      |> Keyword.get(
        :batch_size,
        Application.get_env(:textbin, :expiration_cleanup_batch_size, @default_batch_size)
      )
      |> positive_integer!(:batch_size)

    initial_delay_ms =
      opts
      |> Keyword.get(:initial_delay_ms, 0)
      |> non_negative_integer!(:initial_delay_ms)

    state = %{interval_ms: interval_ms, batch_size: batch_size}
    {:ok, schedule_cleanup(state, initial_delay_ms)}
  end

  @impl true
  def handle_call(:run_now, _from, state) do
    {:reply, clean_batch(state), state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    next_delay_ms =
      case clean_batch(state) do
        deleted_count when deleted_count == state.batch_size -> 0
        _deleted_count_or_error -> state.interval_ms
      end

    {:noreply, schedule_cleanup(state, next_delay_ms)}
  end

  defp clean_batch(state) do
    started_at = System.monotonic_time()

    try do
      deleted_count = Pastes.delete_expired_pastes(limit: state.batch_size)

      :telemetry.execute(
        @telemetry_event,
        %{duration: System.monotonic_time() - started_at, deleted_count: deleted_count},
        %{batch_size: state.batch_size, result: :ok}
      )

      if deleted_count > 0 do
        Logger.info("Deleted #{deleted_count} expired pastes")
      end

      deleted_count
    rescue
      exception ->
        :telemetry.execute(
          @telemetry_event,
          %{duration: System.monotonic_time() - started_at, deleted_count: 0},
          %{batch_size: state.batch_size, result: :error}
        )

        Logger.error("Failed to delete expired pastes: #{Exception.message(exception)}")
        :error
    end
  end

  defp schedule_cleanup(state, delay_ms) do
    Process.send_after(self(), :cleanup, delay_ms)
    state
  end

  defp positive_integer!(value, _name) when is_integer(value) and value > 0, do: value

  defp positive_integer!(value, name) do
    raise ArgumentError, "#{inspect(name)} must be a positive integer, got: #{inspect(value)}"
  end

  defp non_negative_integer!(value, _name) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer!(value, name) do
    raise ArgumentError,
          "#{inspect(name)} must be a non-negative integer, got: #{inspect(value)}"
  end
end
