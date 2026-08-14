defmodule Textbin.Organizations.ConcurrencyTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Textbin.Accounts.Scope
  alias Textbin.Organizations
  alias Textbin.Organizations.{OrganizationMembership, Workspace, WorkspaceMembership}
  alias Textbin.Pastes
  alias Textbin.Repo

  import Ecto.Query
  import Textbin.AccountsFixtures

  setup do
    :ok = Sandbox.checkout(Repo, sandbox: false)
    {:ok, cleanup} = Agent.start(fn -> %{organization_ids: [], user_ids: []} end)
    Process.put(:concurrency_cleanup, cleanup)

    on_exit(fn ->
      ids = Agent.get(cleanup, & &1)

      :ok = Sandbox.checkout(Repo, sandbox: false)

      try do
        Repo.delete_all(
          from organization in Textbin.Organizations.Organization,
            where: organization.id in ^ids.organization_ids
        )

        Repo.delete_all(
          from user in Textbin.Accounts.User,
            where: user.id in ^ids.user_ids
        )
      after
        Sandbox.checkin(Repo)
        Agent.stop(cleanup)
      end
    end)

    :ok
  end

  test "two organization owners cannot concurrently demote one another" do
    %{owner_a: owner_a, owner_b: owner_b, organization: organization, org_b: org_b} =
      two_owner_fixture()

    org_a =
      Repo.get_by!(OrganizationMembership,
        organization_id: organization.id,
        user_id: owner_a.id
      )

    results =
      race(organization.id, [
        fn ->
          Organizations.change_organization_member_role(Scope.for_user(owner_a), org_b, "member")
        end,
        fn ->
          Organizations.change_organization_member_role(Scope.for_user(owner_b), org_a, "member")
        end
      ])

    assert one_success_and_one_error?(results, [:unauthorized])

    assert Repo.aggregate(
             from(m in OrganizationMembership,
               where: m.organization_id == ^organization.id and m.role == "owner"
             ),
             :count
           ) == 1
  end

  test "two workspace owners cannot concurrently demote one another" do
    %{owner_a: owner_a, owner_b: owner_b, workspace: workspace, workspace_b: workspace_b} =
      fixture = two_owner_fixture()

    workspace_a =
      Repo.get_by!(WorkspaceMembership, workspace_id: workspace.id, user_id: owner_a.id)

    results =
      race(fixture.organization.id, [
        fn ->
          Organizations.change_workspace_member_role(
            Scope.for_user(owner_a),
            workspace_b,
            "member"
          )
        end,
        fn ->
          Organizations.change_workspace_member_role(
            Scope.for_user(owner_b),
            workspace_a,
            "member"
          )
        end
      ])

    assert one_success_and_one_error?(results, [:unauthorized])

    assert Repo.aggregate(
             from(m in WorkspaceMembership,
               where: m.workspace_id == ^fixture.workspace.id and m.role == "owner"
             ),
             :count
           ) == 1
  end

  test "organization removal racing a workspace owner transition is atomic and owner-safe" do
    fixture = two_owner_fixture()

    workspace_a =
      Repo.get_by!(WorkspaceMembership,
        workspace_id: fixture.workspace.id,
        user_id: fixture.owner_a.id
      )

    results =
      race(fixture.organization.id, [
        fn ->
          Organizations.remove_organization_member(
            Scope.for_user(fixture.owner_a),
            fixture.org_b
          )
        end,
        fn ->
          Organizations.change_workspace_member_role(
            Scope.for_user(fixture.owner_b),
            workspace_a,
            "member"
          )
        end
      ])

    assert match?([{:ok, _}, {:error, :not_found}], results) or
             match?([{:error, :last_workspace_owner}, {:ok, _}], results)

    org_b_present? = Repo.get(OrganizationMembership, fixture.org_b.id) != nil
    workspace_b_present? = Repo.get(WorkspaceMembership, fixture.workspace_b.id) != nil
    assert org_b_present? == workspace_b_present?

    case results do
      [{:ok, _}, {:error, :not_found}] ->
        refute org_b_present?

      [{:error, :last_workspace_owner}, {:ok, _}] ->
        assert org_b_present?
        assert Repo.get!(WorkspaceMembership, workspace_a.id).role == "member"
    end

    assert Repo.aggregate(
             from(m in OrganizationMembership,
               where: m.organization_id == ^fixture.organization.id and m.role == "owner"
             ),
             :count
           ) >= 1

    assert Repo.aggregate(
             from(m in WorkspaceMembership,
               where: m.workspace_id == ^fixture.workspace.id and m.role == "owner"
             ),
             :count
           ) >= 1
  end

  test "concurrent duplicate organization add has one constraint failure and no default drift" do
    owner = tracked_user_fixture()
    member = tracked_user_fixture()

    {:ok, organization} =
      Organizations.create_organization(Scope.for_user(owner), %{
        name: "Duplicate race",
        slug: "duplicate-race-#{System.unique_integer([:positive])}"
      })

    track_organization(organization)

    results =
      race(organization.id, [
        fn ->
          Organizations.add_organization_member(Scope.for_user(owner), organization, member)
        end,
        fn ->
          Organizations.add_organization_member(Scope.for_user(owner), organization, member)
        end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %Ecto.Changeset{}}, &1)) == 1

    workspace = hd(organization.workspaces)

    organization_users =
      Repo.all(
        from(m in OrganizationMembership,
          where: m.organization_id == ^organization.id,
          select: m.user_id
        )
      )
      |> MapSet.new()

    workspace_users =
      Repo.all(
        from(m in WorkspaceMembership,
          where: m.workspace_id == ^workspace.id,
          select: m.user_id
        )
      )
      |> MapSet.new()

    expected_users = MapSet.new([owner.id, member.id])
    assert organization_users == expected_users
    assert workspace_users == expected_users
  end

  test "concurrent duplicate non-default workspace add inserts one membership" do
    owner = tracked_user_fixture()
    member = tracked_user_fixture()

    {:ok, organization} =
      Organizations.create_organization(Scope.for_user(owner), %{
        name: "Workspace duplicate race",
        slug: "workspace-duplicate-race-#{System.unique_integer([:positive])}"
      })

    track_organization(organization)

    {:ok, _} =
      Organizations.add_organization_member(Scope.for_user(owner), organization, member)

    workspace = non_default_workspace_fixture(organization, owner)
    workspace_membership_fixture(workspace, owner, "owner")

    results =
      race(organization.id, [
        fn -> Organizations.add_workspace_member(Scope.for_user(owner), workspace, member) end,
        fn -> Organizations.add_workspace_member(Scope.for_user(owner), workspace, member) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %Ecto.Changeset{}}, &1)) == 1

    assert Repo.aggregate(
             from(m in WorkspaceMembership,
               where: m.workspace_id == ^workspace.id and m.user_id == ^member.id
             ),
             :count
           ) == 1
  end

  test "concurrent open workspace joins insert one membership" do
    owner = tracked_user_fixture()
    member = tracked_user_fixture()

    {:ok, organization} =
      Organizations.create_organization(Scope.for_user(owner), %{
        name: "Join race",
        slug: "join-race-#{System.unique_integer([:positive])}"
      })

    track_organization(organization)

    {:ok, _} =
      Organizations.add_organization_member(Scope.for_user(owner), organization, member)

    {:ok, workspace} =
      Organizations.create_workspace(Scope.for_user(owner), organization, %{
        name: "Open",
        slug: "open",
        visibility: "open"
      })

    results =
      race(organization.id, [
        fn -> Organizations.join_workspace(Scope.for_user(member), workspace) end,
        fn -> Organizations.join_workspace(Scope.for_user(member), workspace) end
      ])

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, %Ecto.Changeset{}}, &1)) == 1

    assert Repo.aggregate(
             from(m in WorkspaceMembership,
               where: m.workspace_id == ^workspace.id and m.user_id == ^member.id
             ),
             :count
           ) == 1
  end

  test "paste creation rechecks policy after concurrent sharing is disabled" do
    owner = tracked_user_fixture()

    {:ok, organization} =
      Organizations.create_organization(Scope.for_user(owner), %{
        name: "Sharing race",
        slug: "sharing-race-#{System.unique_integer([:positive])}"
      })

    track_organization(organization)
    workspace = hd(organization.workspaces)
    {:ok, scope} = Organizations.resolve_workspace_scope(Scope.for_user(owner), workspace)
    parent = self()

    {:ok, task} =
      Repo.transaction(fn ->
        workspace =
          Repo.one!(
            from workspace in Workspace,
              where: workspace.id == ^workspace.id,
              lock: "FOR UPDATE"
          )

        workspace
        |> Workspace.changeset(%{external_sharing_policy: "disabled"})
        |> Repo.update!()

        task =
          Task.async(fn ->
            :ok = Sandbox.checkout(Repo, sandbox: false)

            try do
              %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
              send(parent, {:creator_ready, backend_pid})
              Pastes.create_paste(scope, %{data: "raced public paste", audience: "public"})
            after
              Sandbox.checkin(Repo)
            end
          end)

        assert_receive {:creator_ready, backend_pid}, 5_000
        await_lock_waits!([backend_pid], 5_000)
        task
      end)

    assert {:error, changeset} = Task.await(task, 10_000)
    assert {"is disabled by the workspace policy", _} = changeset.errors[:audience]

    refute Repo.exists?(
             from paste in Textbin.Pastes.Paste,
               where: paste.workspace_id == ^workspace.id and paste.audience == "public"
           )
  end

  test "paste reads wait for concurrent workspace membership revocation" do
    owner = tracked_user_fixture()
    member = tracked_user_fixture()

    {:ok, organization} =
      Organizations.create_organization(Scope.for_user(owner), %{
        name: "Read revocation race",
        slug: "read-revocation-race-#{System.unique_integer([:positive])}"
      })

    track_organization(organization)

    {:ok, _memberships} =
      Organizations.add_organization_member(Scope.for_user(owner), organization, member)

    {:ok, workspace} =
      Organizations.create_workspace(Scope.for_user(owner), organization, %{
        name: "Revoked reads",
        slug: "revoked-reads",
        visibility: "private"
      })

    {:ok, membership} =
      Organizations.add_workspace_member(Scope.for_user(owner), workspace, member)

    {:ok, owner_scope} =
      Organizations.resolve_workspace_scope(Scope.for_user(owner), workspace)

    {:ok, member_scope} =
      Organizations.resolve_workspace_scope(Scope.for_user(member), workspace)

    {:ok, paste} = Pastes.create_paste(owner_scope, %{data: "revoked content"})
    parent = self()

    {:ok, tasks} =
      Repo.transaction(fn ->
        Repo.one!(
          from workspace in Workspace,
            where: workspace.id == ^workspace.id,
            lock: "FOR UPDATE"
        )

        Repo.delete!(membership)

        tasks =
          for operation <- [
                fn -> Pastes.list_pastes_with_access(member_scope) end,
                fn -> Pastes.get_paste(member_scope, paste.id) end
              ] do
            Task.async(fn ->
              :ok = Sandbox.checkout(Repo, sandbox: false)

              try do
                %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
                send(parent, {:reader_ready, self(), backend_pid})
                receive do: (:go -> operation.())
              after
                Sandbox.checkin(Repo)
              end
            end)
          end

        readers =
          for _task <- tasks do
            assert_receive {:reader_ready, task_pid, backend_pid}, 5_000
            {task_pid, backend_pid}
          end

        Enum.each(readers, fn {task_pid, _backend_pid} -> send(task_pid, :go) end)
        await_lock_waits!(Enum.map(readers, &elem(&1, 1)), 5_000)
        tasks
      end)

    assert [{:error, :not_found}, nil] = Task.await_many(tasks, 10_000)
    Repo.delete!(paste)
  end

  test "workspace creation racing organization removal cannot orphan membership" do
    owner = tracked_user_fixture()
    creator = tracked_user_fixture()

    {:ok, organization} =
      Organizations.create_organization(Scope.for_user(owner), %{
        name: "Creation removal race",
        slug: "creation-removal-race-#{System.unique_integer([:positive])}"
      })

    track_organization(organization)

    {:ok, creator_memberships} =
      Organizations.add_organization_member(Scope.for_user(owner), organization, creator)

    {:ok, creator_organization_membership} =
      Organizations.change_organization_member_role(
        Scope.for_user(owner),
        creator_memberships.organization,
        "admin"
      )

    results =
      race(organization.id, [
        fn ->
          Organizations.create_workspace(Scope.for_user(creator), organization, %{
            name: "Raced",
            slug: "raced",
            visibility: "private"
          })
        end,
        fn ->
          Organizations.remove_organization_member(
            Scope.for_user(owner),
            creator_organization_membership
          )
        end
      ])

    assert match?([{:ok, _}, {:error, :last_workspace_owner}], results) or
             match?([{:error, :not_found}, {:ok, _}], results)

    organization_membership =
      Repo.get_by(OrganizationMembership,
        organization_id: organization.id,
        user_id: creator.id
      )

    workspace_memberships =
      Repo.all(
        from membership in WorkspaceMembership,
          join: workspace in Textbin.Organizations.Workspace,
          on: workspace.id == membership.workspace_id,
          where:
            workspace.organization_id == ^organization.id and membership.user_id == ^creator.id
      )

    assert is_nil(organization_membership) == Enum.empty?(workspace_memberships)
  end

  defp two_owner_fixture do
    owner_a = tracked_user_fixture()
    owner_b = tracked_user_fixture()

    {:ok, organization} =
      Organizations.create_organization(Scope.for_user(owner_a), %{
        name: "Race",
        slug: "race-#{System.unique_integer([:positive])}"
      })

    track_organization(organization)

    {:ok, memberships} =
      Organizations.add_organization_member(Scope.for_user(owner_a), organization, owner_b)

    {:ok, org_b} =
      Organizations.change_organization_member_role(
        Scope.for_user(owner_a),
        memberships.organization,
        "owner"
      )

    {:ok, workspace_b} =
      Organizations.change_workspace_member_role(
        Scope.for_user(owner_a),
        memberships.workspace,
        "owner"
      )

    %{
      owner_a: owner_a,
      owner_b: owner_b,
      organization: organization,
      org_b: org_b,
      workspace: hd(organization.workspaces),
      workspace_b: workspace_b
    }
  end

  # Hold the serialization row until every independent connection is waiting
  # on it, proving the test exercises post-lock reauthorization rather than
  # merely two sequential calls with concurrent task scheduling.
  defp race(organization_id, functions) do
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
      Repo.one!(
        from organization in Textbin.Organizations.Organization,
          where: organization.id == ^organization_id,
          lock: "FOR UPDATE"
      )

      Enum.each(workers, fn {task_pid, _backend_pid} -> send(task_pid, :go) end)
      await_lock_waits!(Enum.map(workers, &elem(&1, 1)), 5_000)
    end)

    Task.await_many(tasks, 10_000)
  end

  defp await_lock_waits!(backend_pids, timeout) do
    assert MapSet.size(MapSet.new(backend_pids)) == length(backend_pids)
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
        flunk("workers did not block on the organization serialization lock")
      end
    end
  end

  defp tracked_user_fixture do
    user = user_fixture()

    Agent.update(Process.get(:concurrency_cleanup), fn state ->
      %{state | user_ids: [user.id | state.user_ids]}
    end)

    user
  end

  defp track_organization(organization) do
    Agent.update(Process.get(:concurrency_cleanup), fn state ->
      %{state | organization_ids: [organization.id | state.organization_ids]}
    end)
  end

  defp non_default_workspace_fixture(organization, creator) do
    slug = "workspace-#{System.unique_integer([:positive])}"

    %Textbin.Organizations.Workspace{
      organization_id: organization.id,
      created_by_id: creator.id,
      is_default: false
    }
    |> Textbin.Organizations.Workspace.changeset(%{
      name: slug,
      slug: slug,
      visibility: "open"
    })
    |> Repo.insert!()
  end

  defp workspace_membership_fixture(workspace, user, role) do
    %WorkspaceMembership{
      workspace_id: workspace.id,
      user_id: user.id,
      created_by_id: user.id,
      role: role
    }
    |> WorkspaceMembership.changeset()
    |> Repo.insert!()
  end

  defp one_success_and_one_error?(results, allowed_errors) do
    Enum.count(results, &match?({:ok, _}, &1)) == 1 and
      Enum.count(results, fn
        {:error, reason} -> reason in allowed_errors
        _ -> false
      end) == 1
  end
end
