defmodule Textbin.AccountsConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Textbin.Accounts
  alias Textbin.Accounts.User
  alias Textbin.Repo

  import Ecto.Query
  import Textbin.AccountsFixtures

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    {:ok, cleanup} = Agent.start(fn -> [] end)
    Process.put(:accounts_concurrency_cleanup, cleanup)

    on_exit(fn ->
      user_ids = Agent.get(cleanup, & &1)
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        Repo.delete_all(from user in User, where: user.id in ^user_ids)
      after
        Sandbox.checkin(Repo)
        Agent.stop(cleanup)
      end
    end)

    :ok
  end

  test "only one concurrent email confirmation can succeed" do
    user = tracked_user_fixture()
    first_email = unique_user_email()
    second_email = unique_user_email()

    first_token = email_change_token(user, first_email)
    second_token = email_change_token(user, second_email)

    results =
      race_email_confirmations(user, [
        fn -> Accounts.update_user_email(user, first_token) end,
        fn -> Accounts.update_user_email(user, second_token) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1

    assert Enum.count(results, fn
             {:error, :transaction_aborted} -> true
             _ -> false
           end) == 1

    assert Repo.get!(User, user.id).email in [first_email, second_email]
  end

  defp email_change_token(user, email) do
    extract_user_token(fn url ->
      Accounts.deliver_user_update_email_instructions(%{user | email: email}, user.email, url)
    end)
  end

  defp tracked_user_fixture do
    user = user_fixture()
    Agent.update(Process.get(:accounts_concurrency_cleanup), &[user.id | &1])
    user
  end

  # Hold the user row until both independent connections are waiting on it,
  # proving both confirmation attempts overlap at the serialization boundary.
  defp race_email_confirmations(user, functions) do
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
      Repo.one!(from candidate in User, where: candidate.id == ^user.id, lock: "FOR UPDATE")
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
        flunk("workers did not block on the user serialization lock")
      end
    end
  end
end
