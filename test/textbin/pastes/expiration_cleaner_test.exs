defmodule Textbin.Pastes.ExpirationCleanerTest do
  use Textbin.DataCase, async: false

  alias Textbin.Pastes.ExpirationCleaner
  alias Textbin.Pastes.Paste

  import Textbin.AccountsFixtures

  test "run_now/1 deletes one batch and emits telemetry" do
    user = user_fixture()
    workspace = personal_workspace_fixture(user)

    expired_paste =
      Repo.insert!(%Paste{
        data: "expired",
        syntax_highlight: "plain",
        audience: "workspace",
        workspace_id: workspace.id,
        created_by_user_id: user.id,
        expires_at: DateTime.add(Paste.utc_now_ms(), -1, :second)
      })

    handler_id = "expiration-cleaner-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:textbin, :pastes, :expiration_cleanup],
      fn event, measurements, metadata, test_pid ->
        send(test_pid, {:cleanup_telemetry, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    cleaner =
      start_supervised!(
        {ExpirationCleaner,
         name: nil, initial_delay_ms: :timer.hours(1), interval_ms: :timer.hours(1), batch_size: 1}
      )

    Ecto.Adapters.SQL.Sandbox.allow(Textbin.Repo, self(), cleaner)

    assert ExpirationCleaner.run_now(cleaner) == 1
    refute Repo.get(Paste, expired_paste.id)

    assert_receive {:cleanup_telemetry, [:textbin, :pastes, :expiration_cleanup], measurements,
                    metadata}

    assert measurements.deleted_count == 1
    assert is_integer(measurements.duration)
    assert metadata == %{batch_size: 1, result: :ok}
  end
end
