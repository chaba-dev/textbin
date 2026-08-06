defmodule Textbin.PastesTest do
  use Textbin.DataCase, async: true

  alias Textbin.Pastes
  alias Textbin.Pastes.Paste
  alias Textbin.Storage

  import Textbin.AccountsFixtures

  describe "pastes" do
    @valid_attrs %{data: "some data"}
    @invalid_attrs %{data: nil}

    setup do
      user = user_fixture()
      %{scope: user_scope_fixture(user), other_scope: user_scope_fixture()}
    end

    test "list_pastes/1 returns scoped pastes", %{scope: scope, other_scope: other_scope} do
      {:ok, older_paste} = Pastes.create_paste(scope, @valid_attrs)
      {:ok, newer_paste} = Pastes.create_paste(scope, %{data: "newer data"})
      {:ok, other_paste} = Pastes.create_paste(other_scope, %{data: "other user data"})

      paste_ids = Pastes.list_pastes(scope) |> Enum.map(& &1.id)

      assert older_paste.id in paste_ids
      assert newer_paste.id in paste_ids
      refute other_paste.id in paste_ids
      assert Enum.all?(Pastes.list_pastes(scope), &is_binary(&1.data))
    end

    test "list_paste_metadata/1 does not load paste bodies", %{scope: scope} do
      {:ok, inline_paste} = Pastes.create_paste(scope, %{data: "inline"})
      {:ok, blob_paste} = Pastes.create_paste(scope, %{data: String.duplicate("a", 8_193)})

      listed_pastes = Pastes.list_paste_metadata(scope)

      assert MapSet.new(listed_pastes, & &1.id) == MapSet.new([inline_paste.id, blob_paste.id])
      assert Enum.all?(listed_pastes, &is_nil(&1.data))
    end

    test "get_paste!/2 returns the scoped paste with given id", %{scope: scope} do
      {:ok, paste} = Pastes.create_paste(scope, @valid_attrs)

      assert Pastes.get_paste!(scope, paste.id).id == paste.id
    end

    test "get_paste!/2 raises for another user's paste", %{scope: scope, other_scope: other_scope} do
      {:ok, paste} = Pastes.create_paste(other_scope, @valid_attrs)

      assert_raise Ecto.NoResultsError, fn -> Pastes.get_paste!(scope, paste.id) end
    end

    test "get_shared_paste/2 allows anonymous access to unlisted and public pastes", %{
      scope: scope
    } do
      for visibility <- ["unlisted", "public"] do
        {:ok, paste} =
          Pastes.create_paste(scope, %{data: visibility, visibility: visibility})

        assert Pastes.get_shared_paste(nil, paste.id).id == paste.id
      end
    end

    test "get_shared_paste/2 allows an owner to access a private paste", %{scope: scope} do
      {:ok, paste} = Pastes.create_paste(scope, %{data: "private", visibility: "private"})

      assert Pastes.get_shared_paste(scope, paste.id).id == paste.id
    end

    test "get_shared_paste/2 hides private pastes from other viewers", %{
      scope: scope,
      other_scope: other_scope
    } do
      {:ok, paste} = Pastes.create_paste(scope, %{data: "private", visibility: "private"})

      refute Pastes.get_shared_paste(nil, paste.id)
      refute Pastes.get_shared_paste(other_scope, paste.id)
    end

    test "get_shared_paste/2 hides expired shared pastes", %{scope: scope} do
      expired_paste =
        Repo.insert!(%Paste{
          data: "expired shared data",
          syntax_highlight: "plain",
          visibility: "public",
          user_id: scope.user.id,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
        })

      refute Pastes.get_shared_paste(nil, expired_paste.id)
      refute Pastes.get_shared_paste(scope, expired_paste.id)
    end

    test "get_shared_paste/2 returns nil for an invalid id", %{scope: scope} do
      refute Pastes.get_shared_paste(nil, "not-a-uuid")
      refute Pastes.get_shared_paste(scope, "not-a-uuid")
    end

    test "create_paste/2 with valid data creates a paste", %{scope: scope} do
      assert {:ok, %Paste{} = paste} = Pastes.create_paste(scope, @valid_attrs)
      assert paste.data == "some data"
      assert paste.size_bytes == byte_size("some data")
      assert paste.sha256 == :crypto.hash(:sha256, "some data")
      assert paste.storage_key == nil
      assert Repo.get!(Paste, paste.id).data == "some data"
      assert paste.syntax_highlight == "plain"
      assert paste.visibility == "private"
      assert paste.user_id == scope.user.id
      assert {microsecond, 6} = paste.inserted_at.microsecond
      assert rem(microsecond, 1000) == 0
      assert is_nil(paste.expires_at)
    end

    test "create_paste/2 stores content at the inline threshold in PostgreSQL", %{scope: scope} do
      data = String.duplicate("a", 8_192)

      assert {:ok, %Paste{} = paste} = Pastes.create_paste(scope, %{data: data})
      assert paste.data == data
      assert paste.storage_key == nil
      assert paste.size_bytes == byte_size(data)
      assert paste.sha256 == :crypto.hash(:sha256, data)
    end

    test "create_paste/2 stores content over the inline threshold in blob storage", %{
      scope: scope
    } do
      data = String.duplicate("a", 8_193)

      assert {:ok, %Paste{} = paste} = Pastes.create_paste(scope, %{data: data})
      assert paste.data == data
      assert paste.storage_key == "pastes/#{paste.id}"
      assert Storage.get(paste.storage_key) == {:ok, data}
      assert Repo.get!(Paste, paste.id).data == nil
    end

    test "create_paste/2 keeps PostgreSQL-unsafe small content in blob storage", %{scope: scope} do
      for data <- ["contains\0null", <<255, 254, 253>>] do
        assert {:ok, %Paste{} = paste} = Pastes.create_paste(scope, %{data: data})
        assert paste.storage_key == "pastes/#{paste.id}"
        assert Storage.get(paste.storage_key) == {:ok, data}
        assert Repo.get!(Paste, paste.id).data == nil
      end
    end

    test "create_paste/2 stores the syntax highlight", %{scope: scope} do
      assert {:ok, %Paste{} = paste} =
               Pastes.create_paste(scope, %{data: "IO.puts(:ok)", syntax_highlight: "elixir"})

      assert paste.data == "IO.puts(:ok)"
      assert paste.syntax_highlight == "elixir"
    end

    test "create_paste/2 stores every registered-user visibility", %{scope: scope} do
      for visibility <- ["private", "unlisted", "public"] do
        assert {:ok, %Paste{} = paste} =
                 Pastes.create_paste(scope, %{data: visibility, visibility: visibility})

        assert paste.visibility == visibility
      end
    end

    test "create_paste/2 forces guest pastes to unlisted" do
      {:ok, guest_user} = Textbin.Accounts.create_guest_user()
      guest_scope = Textbin.Accounts.Scope.for_user(guest_user)

      for requested_visibility <- [nil, "private", "unlisted", "public"] do
        attrs =
          %{data: "guest visibility"}
          |> Map.put(:visibility, requested_visibility)

        assert {:ok, %Paste{visibility: "unlisted"}} = Pastes.create_paste(guest_scope, attrs)
      end
    end

    test "create_paste/2 stores a selected expiration", %{scope: scope} do
      assert {:ok, %Paste{} = paste} =
               Pastes.create_paste(scope, %{data: "short lived", expires_in: "1h"})

      assert DateTime.diff(paste.expires_at, DateTime.utc_now(), :second) in 3590..3600
    end

    test "create_paste/2 supports 6h and 12h expirations", %{scope: scope} do
      assert {:ok, %Paste{} = six_hour_paste} =
               Pastes.create_paste(scope, %{data: "six hours", expires_in: "6h"})

      assert DateTime.diff(six_hour_paste.expires_at, DateTime.utc_now(), :second) in 21_590..21_600

      assert {:ok, %Paste{} = twelve_hour_paste} =
               Pastes.create_paste(scope, %{data: "twelve hours", expires_in: "12h"})

      assert DateTime.diff(twelve_hour_paste.expires_at, DateTime.utc_now(), :second) in 43_190..43_200
    end

    test "create_paste/2 uses the user's default expiration", %{scope: scope} do
      {:ok, user} =
        Textbin.Accounts.update_user_paste_defaults(scope.user, %{default_paste_ttl: "1d"})

      scope = %{scope | user: user}

      assert {:ok, %Paste{} = paste} = Pastes.create_paste(scope, %{data: "user default"})

      assert DateTime.diff(paste.expires_at, DateTime.utc_now(), :second) in 86_390..86_400
    end

    test "create_paste/2 explicit expiration overrides the user's default", %{scope: scope} do
      {:ok, user} =
        Textbin.Accounts.update_user_paste_defaults(scope.user, %{default_paste_ttl: "1d"})

      scope = %{scope | user: user}

      assert {:ok, %Paste{} = paste} =
               Pastes.create_paste(scope, %{data: "explicit default", expires_in: "never"})

      assert is_nil(paste.expires_at)
    end

    test "create_paste/2 with invalid data returns error changeset", %{scope: scope} do
      assert {:error, %Ecto.Changeset{}} = Pastes.create_paste(scope, @invalid_attrs)
    end

    test "create_paste/2 rejects data over the configured size limit", %{scope: scope} do
      oversized_data = String.duplicate("a", 1_048_577)

      assert {:error, changeset} = Pastes.create_paste(scope, %{data: oversized_data})
      assert %{data: ["must be at most 1048576 bytes"]} = errors_on(changeset)
    end

    test "create_paste_from_file/4 stores streamed content and metadata", %{scope: scope} do
      path = Path.join(System.tmp_dir!(), "textbin-context-upload-#{Ecto.UUID.generate()}")
      data = String.duplicate("streamed context data\n", 4_000)
      metadata = %{size_bytes: byte_size(data), sha256: :crypto.hash(:sha256, data)}
      File.write!(path, data)
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %Paste{} = paste} =
               Pastes.create_paste_from_file(scope, path, metadata, %{syntax_highlight: "text"})

      assert paste.data == nil
      assert paste.size_bytes == metadata.size_bytes
      assert paste.sha256 == metadata.sha256
      assert File.exists?(path)
      assert Pastes.get_paste!(scope, paste.id).data == data
    end

    test "create_paste_from_file/4 stores a small streamed paste inline", %{scope: scope} do
      path = Path.join(System.tmp_dir!(), "textbin-context-upload-#{Ecto.UUID.generate()}")
      data = String.duplicate("a", 8_192)
      metadata = %{size_bytes: byte_size(data), sha256: :crypto.hash(:sha256, data)}
      File.write!(path, data)
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %Paste{} = paste} =
               Pastes.create_paste_from_file(scope, path, metadata)

      assert paste.data == data
      assert paste.storage_key == nil
      assert paste.size_bytes == metadata.size_bytes
      assert paste.sha256 == metadata.sha256
      assert File.exists?(path)
    end

    test "create_paste_from_file/4 rejects metadata that does not match the file", %{
      scope: scope
    } do
      path = Path.join(System.tmp_dir!(), "textbin-context-upload-#{Ecto.UUID.generate()}")
      File.write!(path, "actual data")
      on_exit(fn -> File.rm(path) end)

      metadata = %{size_bytes: 1, sha256: :crypto.hash(:sha256, "actual data")}

      assert {:error, changeset} = Pastes.create_paste_from_file(scope, path, metadata)
      assert %{data: ["does not match the uploaded file"]} = errors_on(changeset)
      assert Repo.aggregate(Paste, :count) == 0
    end

    test "create_paste_from_file/4 rejects a same-size SHA-256 mismatch", %{scope: scope} do
      path = Path.join(System.tmp_dir!(), "textbin-context-upload-#{Ecto.UUID.generate()}")
      data = "actual data"
      File.write!(path, data)
      on_exit(fn -> File.rm(path) end)

      metadata = %{size_bytes: byte_size(data), sha256: :crypto.hash(:sha256, "other data!")}

      assert {:error, changeset} = Pastes.create_paste_from_file(scope, path, metadata)
      assert %{data: ["does not match the uploaded file"]} = errors_on(changeset)
      assert Repo.aggregate(Paste, :count) == 0
    end

    test "create_paste/2 with an invalid expiration returns error changeset", %{scope: scope} do
      assert {:error, changeset} =
               Pastes.create_paste(scope, %{data: "bad ttl", expires_in: "forever"})

      assert %{expires_at: ["must use one of: never, 10m, 1h, 6h, 12h, 1d, 7d, 30d"]} =
               errors_on(changeset)
    end

    test "create_paste/2 with an invalid visibility returns error changeset", %{scope: scope} do
      assert {:error, changeset} =
               Pastes.create_paste(scope, %{data: "bad visibility", visibility: "secret"})

      assert %{visibility: ["is invalid"]} = errors_on(changeset)
    end

    test "expired pastes are excluded from scoped reads", %{scope: scope} do
      expired_paste =
        Repo.insert!(%Paste{
          data: "expired data",
          syntax_highlight: "plain",
          user_id: scope.user.id,
          expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
        })

      refute expired_paste.id in (Pastes.list_pastes(scope) |> Enum.map(& &1.id))
      refute Pastes.get_paste(scope, expired_paste.id)
      assert_raise Ecto.NoResultsError, fn -> Pastes.get_paste!(scope, expired_paste.id) end
    end

    test "delete_paste/2 deletes the scoped paste", %{scope: scope} do
      {:ok, paste} = Pastes.create_paste(scope, @valid_attrs)

      assert {:ok, %Paste{}} = Pastes.delete_paste(scope, paste)
      assert_raise Ecto.NoResultsError, fn -> Pastes.get_paste!(scope, paste.id) end
      assert paste.storage_key == nil
    end

    test "reads legacy database-backed paste content", %{scope: scope} do
      paste =
        Repo.insert!(%Paste{
          data: "legacy content",
          syntax_highlight: "plain",
          visibility: "private",
          user_id: scope.user.id
        })

      assert Pastes.get_paste!(scope, paste.id).data == "legacy content"
    end

    test "delete_paste/2 does not delete another user's paste", %{
      scope: scope,
      other_scope: other_scope
    } do
      {:ok, paste} = Pastes.create_paste(other_scope, @valid_attrs)

      assert Pastes.delete_paste(scope, paste) == {:error, :not_found}
      assert Pastes.get_paste!(other_scope, paste.id)
    end

    test "delete_expired_pastes/1 deletes the oldest expired rows in bounded batches", %{
      scope: scope
    } do
      now = Paste.utc_now_ms()

      oldest_expired =
        insert_paste!(scope, "oldest expired", DateTime.add(now, -2, :second))

      newly_expired = insert_paste!(scope, "newly expired", now)
      active = insert_paste!(scope, "active", DateTime.add(now, 1, :hour))
      never_expires = insert_paste!(scope, "never", nil)

      assert Pastes.delete_expired_pastes(now: now, limit: 1) == 1
      refute Repo.get(Paste, oldest_expired.id)
      assert Repo.get(Paste, newly_expired.id)

      assert Pastes.delete_expired_pastes(now: now, limit: 1) == 1
      refute Repo.get(Paste, newly_expired.id)
      assert Repo.get(Paste, active.id)
      assert Repo.get(Paste, never_expires.id)

      assert Pastes.delete_expired_pastes(now: now, limit: 1) == 0
    end

    test "delete_expired_pastes/1 rejects invalid batch limits" do
      assert_raise ArgumentError, ":limit must be a positive integer", fn ->
        Pastes.delete_expired_pastes(limit: 0)
      end
    end

    test "change_paste/3 returns a paste changeset", %{scope: scope} do
      assert %Ecto.Changeset{} = Pastes.change_paste(scope, %Paste{})
    end

    defp insert_paste!(scope, data, expires_at) do
      Repo.insert!(%Paste{
        data: data,
        syntax_highlight: "plain",
        visibility: "private",
        user_id: scope.user.id,
        expires_at: expires_at
      })
    end
  end
end
