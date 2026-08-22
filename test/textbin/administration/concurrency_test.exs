defmodule Textbin.Administration.ConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Textbin.Accounts.Scope
  alias Textbin.Accounts.User
  alias Textbin.Administration
  alias Textbin.Repo

  import Ecto.Query
  import Textbin.AccountsFixtures

  @authority_lock_key 8_174_021_483_001

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    Repo.query!("TRUNCATE platform_audit_events")
    {:ok, cleanup} = Agent.start(fn -> [] end)

    on_exit(fn ->
      user_ids = Agent.get(cleanup, & &1)
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        Repo.query!("TRUNCATE platform_audit_events")
        Repo.delete_all(from user in User, where: user.id in ^user_ids)
      after
        Sandbox.checkin(Repo)
        Agent.stop(cleanup)
      end
    end)

    %{cleanup: cleanup}
  end

  test "concurrent administrators cannot revoke one another and remove all authority", %{
    cleanup: cleanup
  } do
    admin_a = tracked_admin_fixture(cleanup)
    admin_b = tracked_admin_fixture(cleanup)

    results =
      race([
        fn ->
          Administration.revoke_platform_admin(admin_scope(admin_a), admin_b, "race")
        end,
        fn ->
          Administration.revoke_platform_admin(admin_scope(admin_b), admin_a, "race")
        end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :forbidden}, &1)) == 1

    assert Repo.aggregate(
             from(user in User,
               where:
                 user.platform_role == "admin" and not is_nil(user.confirmed_at) and
                   is_nil(user.suspended_at)
             ),
             :count
           ) == 1
  end

  defp race(functions) do
    parent = self()

    tasks =
      Enum.map(functions, fn function ->
        Task.async(fn ->
          :ok = Sandbox.checkout(Repo, sandbox: false)

          try do
            %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:ready, self(), backend_pid})
            receive do: (:go -> function.())
          after
            Sandbox.checkin(Repo)
          end
        end)
      end)

    workers =
      Enum.map(tasks, fn _task ->
        assert_receive {:ready, task_pid, backend_pid}, 5_000
        {task_pid, backend_pid}
      end)

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1)", [@authority_lock_key])
      Enum.each(workers, fn {task_pid, _backend_pid} -> send(task_pid, :go) end)
      await_lock_waits!(Enum.map(workers, &elem(&1, 1)), 5_000)
    end)

    Task.await_many(tasks, 10_000)
  end

  defp await_lock_waits!(backend_pids, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await_lock_waits!(backend_pids, deadline)
  end

  defp do_await_lock_waits!(backend_pids, deadline) do
    %{rows: rows} =
      Repo.query!(
        "SELECT pid FROM pg_stat_activity WHERE pid = ANY($1) AND wait_event_type = 'Lock'",
        [backend_pids]
      )

    if MapSet.new(rows, fn [pid] -> pid end) == MapSet.new(backend_pids) do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        do_await_lock_waits!(backend_pids, deadline)
      else
        flunk("workers did not block on the platform authority lock")
      end
    end
  end

  defp tracked_admin_fixture(cleanup) do
    user = user_fixture()
    Agent.update(cleanup, &[user.id | &1])
    assert {:ok, _result} = Administration.bootstrap_platform_admin(user.email)
    Repo.get!(User, user.id)
  end

  defp admin_scope(user) do
    Scope.for_user(%{user | authenticated_at: DateTime.utc_now(:second)})
  end
end
