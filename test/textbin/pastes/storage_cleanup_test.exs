defmodule Textbin.Pastes.StorageCleanupTest do
  use Textbin.DataCase, async: false

  import ExUnit.CaptureLog
  import Textbin.AccountsFixtures

  alias Textbin.Pastes
  alias Textbin.Pastes.Paste
  alias Textbin.Accounts
  alias Textbin.Organizations
  alias Textbin.Organizations.{Organization, Workspace}
  alias Textbin.Repo
  alias Textbin.Storage

  setup do
    original_config = Application.fetch_env!(:textbin, Storage)
    original_inline_paste_bytes = Application.fetch_env!(:textbin, :inline_paste_bytes)
    root = Path.join(System.tmp_dir!(), "textbin-cleanup-#{Ecto.UUID.generate()}")
    blocked_root = root <> "-blocked"

    Application.put_env(:textbin, Storage,
      adapter: Textbin.Storage.Local,
      opts: [root: root]
    )

    Application.put_env(:textbin, :inline_paste_bytes, 0)

    on_exit(fn ->
      Application.put_env(:textbin, Storage, original_config)
      Application.put_env(:textbin, :inline_paste_bytes, original_inline_paste_bytes)
      File.rm_rf!(root)
      File.rm_rf!(blocked_root)
    end)

    scope = user_scope_fixture()
    %{scope: scope, root: root, blocked_root: blocked_root}
  end

  test "expiration cleanup retains metadata until object deletion succeeds", context do
    {:ok, paste} = Pastes.create_paste(context.scope, %{data: "retry cleanup"})
    expire!(paste)
    block_storage_deletes!(context.blocked_root)

    log = capture_log(fn -> assert Pastes.delete_expired_pastes(limit: 1) == 0 end)
    assert log =~ "Failed to delete stored paste content: :enotdir"
    assert Repo.get(Paste, paste.id)

    use_storage_root(context.root)

    assert Pastes.delete_expired_pastes(limit: 1) == 1
    refute Repo.get(Paste, paste.id)
    assert Storage.get(paste.storage_key) == {:error, :enoent}
  end

  test "manual deletion leaves an invisible tombstone when storage is unavailable", context do
    {:ok, paste} = Pastes.create_paste(context.scope, %{data: "retry manual deletion"})
    block_storage_deletes!(context.blocked_root)

    log =
      capture_log(fn ->
        assert {:error, :enotdir} = Pastes.delete_paste(context.scope, paste)
      end)

    assert log =~ "Failed to delete stored paste content: :enotdir"
    refute Pastes.get_paste(context.scope, paste.id)
    assert Repo.get(Paste, paste.id)

    use_storage_root(context.root)
    assert Pastes.delete_expired_pastes(limit: 1) == 1
    refute Repo.get(Paste, paste.id)
  end

  test "blob reads reject same-size content with the wrong checksum", context do
    {:ok, paste} = Pastes.create_paste(context.scope, %{data: "original content"})
    File.write!(Path.join(context.root, paste.storage_key), "corrupted bytes!")

    assert_raise Textbin.Storage.IntegrityError, ~r/integrity check failed/, fn ->
      Pastes.get_paste!(context.scope, paste.id)
    end
  end

  test "workspace deletion cannot bypass blob cleanup", context do
    {:ok, paste} = Pastes.create_paste(context.scope, %{data: "retained blob"})
    organization = Organizations.get_personal_organization!(context.scope.user)

    assert_raise Ecto.ConstraintError, fn -> Repo.delete!(organization) end

    assert Repo.get(Paste, paste.id)
    assert Storage.get(paste.storage_key) == {:ok, "retained blob"}
  end

  test "account deletion keeps a retryable personal-workspace tombstone on storage failure",
       context do
    {:ok, paste} = Pastes.create_paste(context.scope, %{data: "account cleanup retry"})
    organization = Organizations.get_personal_organization!(context.scope.user)
    workspace = Organizations.get_personal_default_workspace!(context.scope.user)
    block_storage_deletes!(context.blocked_root)

    assert {:error, :storage_cleanup_failed} = Accounts.delete_user(context.scope)
    assert Repo.get(Textbin.Accounts.User, context.scope.user.id)

    assert %Organization{deletion_requested_at: %DateTime{}} =
             Repo.get(Organization, organization.id)

    refute organization.id in Enum.map(
             Organizations.list_available_organizations(context.scope),
             & &1.id
           )

    assert %Workspace{deletion_requested_at: %DateTime{}} = Repo.get(Workspace, workspace.id)
    assert Repo.get(Paste, paste.id)
    refute Pastes.get_paste(context.scope, paste.id)

    use_storage_root(context.root)
    assert {:ok, _user} = Accounts.delete_user(context.scope)
    refute Repo.get(Textbin.Accounts.User, context.scope.user.id)
    refute Repo.get(Organization, organization.id)
    refute Repo.get(Paste, paste.id)
    assert Storage.get(paste.storage_key) == {:error, :enoent}
  end

  test "failed workspace deletion immediately conceals future-TTL shared pastes", context do
    organization = Organizations.get_personal_organization!(context.scope.user)

    {:ok, workspace} =
      Organizations.create_workspace(context.scope, organization, %{
        name: "Shared deletion",
        slug: "shared-deletion",
        visibility: "open",
        external_sharing_policy: "public"
      })

    {:ok, workspace_scope} = Organizations.resolve_workspace_scope(context.scope, workspace)

    {:ok, paste} =
      Pastes.create_paste(workspace_scope, %{
        data: "future shared content",
        audience: "public",
        expires_in: "30d"
      })

    delegate = Application.fetch_env!(:textbin, Storage)

    Application.put_env(:textbin, Storage,
      adapter: Textbin.FailingDeleteStorage,
      opts: [test_pid: self(), delegate: delegate]
    )

    assert {:error, :storage_cleanup_failed} =
             Organizations.delete_workspace(context.scope, workspace)

    assert_receive {:storage_delete_failed, storage_key}
    assert storage_key == paste.storage_key
    refute Pastes.get_shared_paste(nil, paste.id)
    refute Pastes.get_shared_paste(context.scope, paste.id)
  end

  test "account deletion prevents personal workspace creation after cleanup starts", context do
    organization = Organizations.get_personal_organization!(context.scope.user)
    {:ok, _paste} = Pastes.create_paste(context.scope, %{data: "block account cleanup"})
    {:ok, gate} = Agent.start_link(fn -> true end)
    delegate = Application.fetch_env!(:textbin, Storage)

    Application.put_env(:textbin, Storage,
      adapter: Textbin.BlockingStorage,
      opts: [gate: gate, test_pid: self(), delegate: delegate]
    )

    deletion =
      Task.async(fn ->
        try do
          Accounts.delete_user(context.scope)
        rescue
          error -> {:raised, error}
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), deletion.pid)

    assert_receive {:storage_delete_blocked, deleting_pid, storage_key}, 1_000

    create_result =
      Organizations.create_workspace(context.scope, organization, %{
        name: "Too late",
        slug: "too-late",
        visibility: "private"
      })

    send(deleting_pid, {:continue_storage_delete, storage_key})
    deletion_result = Task.await(deletion)

    assert {:error, :not_found} = create_result
    assert {:ok, _user} = deletion_result
  end

  test "shared blob reads hold workspace access stable through content loading", context do
    organization = Organizations.get_personal_organization!(context.scope.user)

    {:ok, workspace} =
      Organizations.create_workspace(context.scope, organization, %{
        name: "Read lock",
        slug: "read-lock",
        visibility: "open",
        external_sharing_policy: "public"
      })

    {:ok, workspace_scope} = Organizations.resolve_workspace_scope(context.scope, workspace)

    {:ok, paste} =
      Pastes.create_paste(workspace_scope, %{data: "stable shared read", audience: "public"})

    {:ok, read_gate} = Agent.start_link(fn -> true end)
    {:ok, delete_gate} = Agent.start_link(fn -> false end)
    delegate = Application.fetch_env!(:textbin, Storage)

    Application.put_env(:textbin, Storage,
      adapter: Textbin.BlockingStorage,
      opts: [
        read_gate: read_gate,
        gate: delete_gate,
        test_pid: self(),
        delegate: delegate
      ]
    )

    read =
      Task.async(fn ->
        try do
          {:ok, Pastes.get_shared_paste(nil, paste.id)}
        rescue
          error -> {:raised, error}
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), read.pid)
    assert_receive {:storage_read_blocked, reading_pid, storage_key}, 1_000

    deletion = Task.async(fn -> Organizations.delete_workspace(context.scope, workspace) end)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), deletion.pid)
    deletion_before_read = Task.yield(deletion, 100)

    send(reading_pid, {:continue_storage_read, storage_key})
    read_result = Task.await(read)

    deletion_result =
      case deletion_before_read do
        nil -> Task.await(deletion)
        {:ok, result} -> result
      end

    assert deletion_before_read == nil
    assert {:ok, %Paste{id: paste_id, data: "stable shared read"}} = read_result
    assert paste_id == paste.id
    assert {:ok, _workspace} = deletion_result
  end

  test "manual deletion succeeds when expiration cleanup wins the hard-delete race", context do
    {:ok, gate} = Agent.start_link(fn -> true end)
    delegate = Application.fetch_env!(:textbin, Storage)

    Application.put_env(:textbin, Storage,
      adapter: Textbin.BlockingStorage,
      opts: [gate: gate, test_pid: self(), delegate: delegate]
    )

    {:ok, paste} = Pastes.create_paste(context.scope, %{data: "concurrent cleanup"})

    deletion =
      Task.async(fn ->
        receive do
          :delete -> Pastes.delete_paste(context.scope, paste)
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Textbin.Repo, self(), deletion.pid)
    send(deletion.pid, :delete)

    assert_receive {:storage_delete_blocked, deleting_pid, storage_key}, 1_000
    assert storage_key == paste.storage_key
    assert Pastes.delete_expired_pastes(limit: 1) == 1

    send(deleting_pid, {:continue_storage_delete, storage_key})

    assert {:ok, %Paste{id: paste_id}} = Task.await(deletion)
    assert paste_id == paste.id
    refute Repo.get(Paste, paste.id)
  end

  defp expire!(paste) do
    paste
    |> Ecto.Changeset.change(expires_at: DateTime.add(Paste.utc_now_ms(), -1, :second))
    |> Repo.update!()
  end

  defp block_storage_deletes!(blocked_root) do
    File.write!(blocked_root, "not a directory")
    use_storage_root(blocked_root)
  end

  defp use_storage_root(root) do
    Application.put_env(:textbin, Storage,
      adapter: Textbin.Storage.Local,
      opts: [root: root]
    )
  end
end
