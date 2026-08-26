defmodule Textbin.Administration.ConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Textbin.Accounts
  alias Textbin.Accounts.{Scope, User, UserToken}
  alias Textbin.Administration
  alias Textbin.Administration.PlatformAuditEvent
  alias Textbin.Pastes
  alias Textbin.Pastes.Paste
  alias Textbin.Repo
  alias Textbin.Reports
  alias Textbin.Reports.Report

  import Ecto.Query
  import Textbin.AccountsFixtures

  @authority_lock_key 8_174_021_483_001

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    Repo.query!("TRUNCATE reports, platform_audit_events")
    {:ok, cleanup} = Agent.start(fn -> [] end)

    on_exit(fn ->
      user_ids = Agent.get(cleanup, & &1)
      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        Repo.query!("TRUNCATE reports, platform_audit_events")
        Repo.delete_all(from paste in Paste, where: paste.created_by_user_id in ^user_ids)
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
             active_admin_query(),
             :count
           ) == 1
  end

  test "suspension racing revocation preserves one active administrator", %{cleanup: cleanup} do
    admin_a = tracked_admin_fixture(cleanup)
    admin_b = tracked_admin_fixture(cleanup)

    results =
      race([
        fn -> Administration.suspend_user(admin_scope(admin_a), admin_b, "race") end,
        fn ->
          Administration.revoke_platform_admin(admin_scope(admin_b), admin_a, "race")
        end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :forbidden}, &1)) == 1
    assert Repo.aggregate(active_admin_query(), :count) == 1
  end

  test "concurrent administrator account deletions preserve one active administrator", %{
    cleanup: cleanup
  } do
    admin_a = tracked_admin_fixture(cleanup)
    admin_b = tracked_admin_fixture(cleanup)

    results =
      race([
        fn -> Accounts.delete_user(admin_scope(admin_a)) end,
        fn -> Accounts.delete_user(admin_scope(admin_b)) end
      ])

    assert Enum.count(results, &match?({:ok, %User{}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :final_active_admin}, &1)) == 1
    assert Repo.aggregate(active_admin_query(), :count) == 1
  end

  test "session, API, and login token issuance serialize with suspension", %{cleanup: cleanup} do
    admin = tracked_admin_fixture(cleanup)

    issuers = [
      session: fn user ->
        try do
          {:ok, Accounts.generate_user_session_token(user)}
        rescue
          ArgumentError -> {:error, :suspended}
        end
      end,
      api: fn user -> Accounts.create_user_api_token(user, %{"name" => "race"}) end,
      login: fn user -> Accounts.deliver_login_instructions(user, & &1) end
    ]

    for {context, issuer} <- issuers do
      user = tracked_user_fixture(cleanup)

      {_issuance_result, suspension_result} =
        race_issuance_with_suspension(admin, user, fn -> issuer.(user) end)

      assert {:ok, {%User{suspended_at: %DateTime{}}, _tokens}} = suspension_result

      assert {:ok, %User{suspended_at: nil}} =
               Administration.restore_user(admin_scope(admin), user, "race complete")

      refute Repo.exists?(
               from token in UserToken,
                 where: token.user_id == ^user.id and token.context == ^Atom.to_string(context)
             )
    end
  end

  test "concurrent report reviews produce one transition and audit event", %{cleanup: cleanup} do
    admin_a = tracked_admin_fixture(cleanup)
    admin_b = tracked_admin_fixture(cleanup)
    owner = tracked_user_fixture(cleanup)
    reporter = tracked_user_fixture(cleanup)

    assert {:ok, paste} =
             Pastes.create_paste(Scope.for_user(owner), %{
               data: "concurrent report",
               audience: "public"
             })

    assert {:ok, report} =
             Reports.create_report(Scope.for_user(reporter), paste.id, %{"category" => "spam"})

    results =
      race([
        fn -> Administration.resolve_report(admin_scope(admin_a), report, "actioned") end,
        fn -> Administration.dismiss_report(admin_scope(admin_b), report, "dismissed") end
      ])

    assert Enum.count(results, &match?({:ok, %{id: _, status: _}}, &1)) == 1
    assert Enum.count(results, &match?({:error, :not_found}, &1)) == 1
    assert Repo.get!(Report, report.id).status in ["actioned", "dismissed"]

    assert Repo.aggregate(
             from(event in PlatformAuditEvent, where: event.target_id == ^report.id),
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

  defp race_issuance_with_suspension(admin, user, issuer) do
    parent = self()

    {:ok, tasks} =
      Repo.transaction(fn ->
        Repo.one!(from candidate in User, where: candidate.id == ^user.id, lock: "FOR UPDATE")

        issuance_task = independent_task(parent, issuer)

        suspension_task =
          independent_task(parent, fn ->
            Administration.suspend_user(admin_scope(admin), user, "race")
          end)

        workers =
          for _task <- [issuance_task, suspension_task] do
            assert_receive {:ready, task_pid, backend_pid}, 5_000
            {task_pid, backend_pid}
          end

        Enum.each(workers, fn {task_pid, _backend_pid} -> send(task_pid, :go) end)
        await_lock_waits!(Enum.map(workers, &elem(&1, 1)), 5_000)

        [issuance_task, suspension_task]
      end)

    tasks
    |> Task.await_many(10_000)
    |> List.to_tuple()
  end

  defp independent_task(parent, function) do
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
    user = tracked_user_fixture(cleanup)
    assert {:ok, _result} = Administration.bootstrap_platform_admin(user.email)
    Repo.get!(User, user.id)
  end

  defp tracked_user_fixture(cleanup) do
    user = user_fixture()
    Agent.update(cleanup, &[user.id | &1])
    user
  end

  defp active_admin_query do
    from user in User,
      where:
        user.platform_role == "admin" and not is_nil(user.confirmed_at) and
          is_nil(user.suspended_at)
  end

  defp admin_scope(user) do
    Scope.for_user(%{user | authenticated_at: DateTime.utc_now(:second)})
  end
end
