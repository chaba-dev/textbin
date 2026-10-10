defmodule Textbin.PastesTest do
  use Textbin.DataCase, async: true

  alias Textbin.Pastes
  alias Textbin.Pastes.Paste
  alias Textbin.Storage
  alias Textbin.Organizations

  import Textbin.AccountsFixtures

  describe "pastes" do
    @valid_attrs %{data: "some data"}
    @invalid_attrs %{data: nil}

    setup do
      user = user_fixture()
      scope = user_scope_fixture(user)

      %{
        scope: scope,
        workspace: personal_workspace_fixture(user),
        other_scope: user_scope_fixture()
      }
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

    test "explicit workspace reads and creates revalidate current membership", %{
      scope: owner_scope
    } do
      member = user_fixture()

      {:ok, organization} =
        Organizations.create_organization(owner_scope, %{
          name: "Revoked access",
          slug: "revoked-access"
        })

      {:ok, workspace} =
        Organizations.create_workspace(owner_scope, organization, %{
          name: "Private",
          slug: "private",
          visibility: "private"
        })

      {:ok, _organization_memberships} =
        Organizations.add_organization_member(owner_scope, organization, member)

      {:ok, membership} =
        Organizations.add_workspace_member(owner_scope, workspace, member)

      {:ok, member_scope} =
        Organizations.resolve_workspace_scope(user_scope_fixture(member), workspace)

      {:ok, paste} = Pastes.create_paste(member_scope, %{data: "before revocation"})
      Repo.delete!(membership)

      assert Pastes.list_pastes(member_scope) == []
      assert Pastes.list_paste_metadata(member_scope) == []
      refute Pastes.get_paste(member_scope, paste.id)
      assert_raise Ecto.NoResultsError, fn -> Pastes.get_paste!(member_scope, paste.id) end

      assert {:error, :not_found} =
               Pastes.create_paste(member_scope, %{data: "after revocation"})
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

    test "get_shared_paste/2 enforces the workspace policy for inconsistent external rows", %{
      scope: scope,
      workspace: workspace
    } do
      {:ok, workspace} =
        Organizations.change_workspace_settings(scope, workspace, %{
          external_sharing_policy: "disabled"
        })

      paste =
        Repo.insert!(%Paste{
          data: "must remain internal",
          audience: "public",
          workspace_id: workspace.id,
          created_by_user_id: scope.user.id
        })

      refute Pastes.get_shared_paste(nil, paste.id)
      assert Pastes.get_shared_paste(scope, paste.id).id == paste.id
    end

    test "get_shared_paste/2 allows an owner to access a private paste", %{scope: scope} do
      {:ok, paste} = Pastes.create_paste(scope, %{data: "private", visibility: "private"})

      assert Pastes.get_shared_paste(scope, paste.id).id == paste.id
    end

    test "get_shared_paste/2 allows a workspace member to access a private paste", %{
      scope: scope,
      other_scope: other_scope
    } do
      {:ok, paste} = Pastes.create_paste(scope, %{data: "private", visibility: "private"})
      organization = Organizations.get_personal_organization!(scope.user)

      assert {:ok, _memberships} =
               Organizations.add_organization_member(scope, organization, other_scope.user)

      assert Pastes.get_shared_paste(other_scope, paste.id).id == paste.id
    end

    test "get_shared_paste/2 hides private pastes from other viewers", %{
      scope: scope,
      other_scope: other_scope
    } do
      {:ok, paste} = Pastes.create_paste(scope, %{data: "private", visibility: "private"})

      refute Pastes.get_shared_paste(nil, paste.id)
      refute Pastes.get_shared_paste(other_scope, paste.id)
    end

    test "get_shared_paste/2 hides expired shared pastes", %{scope: scope, workspace: workspace} do
      expired_paste =
        Repo.insert!(%Paste{
          data: "expired shared data",
          syntax_highlight: "plain",
          audience: "public",
          workspace_id: workspace.id,
          created_by_user_id: scope.user.id,
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
      assert paste.content_type == "text/plain"
      assert paste.syntax_highlight == "plain"
      assert paste.audience == "workspace"
      assert paste.workspace_id == personal_workspace_fixture(scope.user).id
      assert paste.created_by_user_id == scope.user.id
      assert {microsecond, 6} = paste.inserted_at.microsecond
      assert rem(microsecond, 1000) == 0
      assert is_nil(paste.expires_at)
    end

    test "workspace sharing policy limits paste audiences", %{scope: scope} do
      {:ok, organization} =
        Organizations.create_organization(scope, %{name: "Audience", slug: "audience"})

      {:ok, workspace} =
        Organizations.create_workspace(scope, organization, %{
          name: "Private",
          slug: "private",
          visibility: "private"
        })

      {:ok, workspace_scope} = Organizations.resolve_workspace_scope(scope, workspace)

      assert {:ok, %Paste{audience: "workspace"}} =
               Pastes.create_paste(workspace_scope, %{data: "members only", audience: "workspace"})

      for audience <- ["unlisted", "public"] do
        assert {:error, changeset} =
                 Pastes.create_paste(workspace_scope, %{data: audience, audience: audience})

        assert %{audience: ["is disabled by the workspace policy"]} = errors_on(changeset)
      end

      assert {:ok, unlisted_workspace} =
               Organizations.change_workspace_settings(scope, workspace, %{
                 external_sharing_policy: "unlisted"
               })

      {:ok, unlisted_scope} = Organizations.resolve_workspace_scope(scope, unlisted_workspace)

      assert {:ok, %Paste{audience: "unlisted"}} =
               Pastes.create_paste(unlisted_scope, %{data: "by link", audience: "unlisted"})

      assert {:error, changeset} =
               Pastes.create_paste(unlisted_scope, %{data: "discoverable", audience: "public"})

      assert %{audience: ["is disabled by the workspace policy"]} = errors_on(changeset)
    end

    test "removed members retain external link access but lose workspace audience access", %{
      scope: owner_scope
    } do
      member = user_fixture()
      member_scope = user_scope_fixture(member)
      organization = Organizations.get_personal_organization!(owner_scope.user)

      {:ok, memberships} =
        Organizations.add_organization_member(owner_scope, organization, member)

      pastes =
        for audience <- ["workspace", "unlisted", "public"], into: %{} do
          {:ok, paste} =
            Pastes.create_paste(owner_scope, %{data: audience, audience: audience})

          {audience, paste}
        end

      assert Pastes.get_shared_paste(member_scope, pastes["workspace"].id)
      Repo.delete!(memberships.workspace)

      refute Pastes.get_shared_paste(member_scope, pastes["workspace"].id)
      assert Pastes.get_shared_paste(member_scope, pastes["unlisted"].id)
      assert Pastes.get_shared_paste(member_scope, pastes["public"].id)
    end

    test "create_paste/2 derives a title from the first non-blank line", %{scope: scope} do
      data = "\n   # docker-compose.override.yml   \r\nservices:\n  postgres: {}\n"

      assert {:ok, %Paste{} = paste} = Pastes.create_paste(scope, %{data: data})
      assert paste.title == "# docker-compose.override.yml"
      assert Paste.display_title(paste) == "# docker-compose.override.yml"
    end

    test "Unicode metadata persists with grapheme-based limits", %{scope: scope} do
      for grapheme <- ["e\u0301", "👩‍💻"] do
        expected = String.duplicate(grapheme, 120)

        assert {:ok, paste} =
                 Pastes.create_paste(scope, %{data: String.duplicate(grapheme, 121)})

        assert Repo.get!(Paste, paste.id).title == expected

        title = String.duplicate(grapheme, 200)
        url = "https://example.com/" <> String.duplicate(grapheme, 2028)

        assert {:ok, paste} =
                 Pastes.create_paste(scope, %{data: "body", title: title, reference_url: url})

        reloaded = Repo.get!(Paste, paste.id)
        assert reloaded.title == title
        assert reloaded.reference_url == url
      end
    end

    test "create_paste/2 keeps an explicit title and reference link", %{scope: scope} do
      assert {:ok, %Paste{} = paste} =
               Pastes.create_paste(scope, %{
                 data: "first line is not the title",
                 title: "  Compose override  ",
                 reference_url: " https://tracker.example.com/INC-2041 "
               })

      assert paste.title == "Compose override"
      assert paste.reference_url == "https://tracker.example.com/INC-2041"
      assert Repo.get!(Paste, paste.id).title == "Compose override"
    end

    test "create_paste/2 leaves binary pastes untitled", %{scope: scope} do
      for data <- [<<255, 254, 253>>, "valid UTF-8 binary"] do
        assert {:ok, %Paste{} = paste} =
                 Pastes.create_paste(scope, %{
                   data: data,
                   content_type: "application/octet-stream"
                 })

        assert is_nil(paste.title)
        assert Paste.display_title(paste) == "Untitled paste"
      end
    end

    test "create_paste/2 rejects a reference link that is not http or https", %{scope: scope} do
      assert {:error, changeset} =
               Pastes.create_paste(scope, %{data: "some data", reference_url: "INC-2041"})

      assert %{reference_url: ["must start with http:// or https://"]} = errors_on(changeset)
    end

    test "create_paste/2 rejects a title over 200 characters", %{scope: scope} do
      assert {:error, changeset} =
               Pastes.create_paste(scope, %{
                 data: "some data",
                 title: String.duplicate("t", 201)
               })

      assert %{title: ["should be at most 200 character(s)"]} = errors_on(changeset)
    end

    test "list_paste_metadata/1 returns titles and authors", %{scope: scope} do
      {:ok, paste} = Pastes.create_paste(scope, %{data: "find me later\nsecond line"})

      assert [listed] = Pastes.list_paste_metadata(scope)
      assert listed.id == paste.id
      assert listed.title == "find me later"
      assert listed.created_by_user.id == scope.user.id
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
        assert paste.content_type == "application/octet-stream"
        assert Storage.get(paste.storage_key) == {:ok, data}
        assert Repo.get!(Paste, paste.id).data == nil
      end
    end

    test "create_paste/2 normalizes a textual content type and stores it inline", %{scope: scope} do
      assert {:ok, %Paste{} = paste} =
               Pastes.create_paste(scope, %{
                 data: "<strong>safe source</strong>",
                 content_type: "TEXT/HTML; charset=iso-8859-1"
               })

      assert paste.content_type == "text/html"
      assert paste.storage_key == nil
    end

    test "create_paste/2 keeps explicitly binary content in blob storage", %{scope: scope} do
      assert {:ok, %Paste{} = paste} =
               Pastes.create_paste(scope, %{
                 data: "valid UTF-8 bytes",
                 content_type: "application/octet-stream"
               })

      assert paste.content_type == "application/octet-stream"
      assert paste.storage_key == "pastes/#{paste.id}"
    end

    test "create_paste/2 rejects an invalid content type", %{scope: scope} do
      assert {:error, changeset} =
               Pastes.create_paste(scope, %{data: "content", content_type: "not a media type"})

      assert %{content_type: ["is invalid"]} = errors_on(changeset)
    end

    test "create_paste/2 rejects a content type that exceeds the database limit", %{scope: scope} do
      content_type = "application/" <> String.duplicate("a", 244)

      assert {:error, changeset} =
               Pastes.create_paste(scope, %{data: "content", content_type: content_type})

      assert %{content_type: ["should be at most 255 character(s)"]} = errors_on(changeset)
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

        assert paste.audience == if(visibility == "private", do: "workspace", else: visibility)
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

      assert %{audience: ["is invalid"]} = errors_on(changeset)
    end

    test "expired pastes are excluded from scoped reads", %{scope: scope, workspace: workspace} do
      expired_paste =
        Repo.insert!(%Paste{
          data: "expired data",
          syntax_highlight: "plain",
          workspace_id: workspace.id,
          created_by_user_id: scope.user.id,
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

    test "delete_paste/2 denies callers without a user", %{scope: scope} do
      {:ok, paste} = Pastes.create_paste(scope, @valid_attrs)

      assert {:error, :not_found} = Pastes.delete_paste(nil, paste)
      assert Repo.get(Paste, paste.id)
    end

    test "reads database-backed paste content by workspace", %{scope: scope, workspace: workspace} do
      paste =
        Repo.insert!(%Paste{
          data: "legacy content",
          syntax_highlight: "plain",
          audience: "workspace",
          workspace_id: workspace.id,
          created_by_user_id: scope.user.id
        })

      assert Pastes.get_paste!(scope, paste.id).data == "legacy content"
    end

    test "workspace ownership survives removal of creator attribution", %{scope: scope} do
      {:ok, paste} = Pastes.create_paste(scope, @valid_attrs)

      paste
      |> Ecto.Changeset.change(created_by_user_id: nil)
      |> Repo.update!()

      assert Pastes.get_paste!(scope, paste.id).id == paste.id
      assert paste.id in Enum.map(Pastes.list_pastes(scope), & &1.id)
    end

    test "deleting a creator retains pastes owned by a team workspace" do
      creator = user_fixture()
      scope = user_scope_fixture(creator)

      {:ok, organization} =
        Organizations.create_organization(scope, %{name: "Acme", slug: "acme"})

      [workspace] = organization.workspaces

      paste =
        Repo.insert!(%Paste{
          data: "team data",
          workspace_id: workspace.id,
          created_by_user_id: creator.id
        })

      Repo.delete!(creator)

      retained_paste = Repo.get!(Paste, paste.id)
      assert retained_paste.workspace_id == workspace.id
      assert retained_paste.created_by_user_id == nil
    end

    test "delete_paste/2 does not delete another user's paste", %{
      scope: scope,
      other_scope: other_scope
    } do
      {:ok, paste} = Pastes.create_paste(other_scope, @valid_attrs)

      assert Pastes.delete_paste(scope, paste) == {:error, :not_found}
      assert Pastes.get_paste!(other_scope, paste.id)
    end

    test "delete_paste/2 ignores ownership fields from a tampered struct", %{
      scope: scope,
      workspace: workspace,
      other_scope: other_scope
    } do
      {:ok, other_paste} = Pastes.create_paste(other_scope, @valid_attrs)

      tampered_paste = %{
        other_paste
        | workspace_id: workspace.id,
          created_by_user_id: scope.user.id,
          storage_key: nil
      }

      assert {:error, :not_found} = Pastes.delete_paste(scope, tampered_paste)
      assert Repo.get(Paste, other_paste.id)
    end

    test "workspace owners manage all pastes while members manage only their own", %{
      scope: owner_scope,
      other_scope: member_scope,
      workspace: workspace
    } do
      organization = Organizations.get_personal_organization!(owner_scope.user)

      assert {:ok, _memberships} =
               Organizations.add_organization_member(owner_scope, organization, member_scope.user)

      owner_paste =
        Repo.insert!(%Paste{
          data: "owner paste",
          workspace_id: workspace.id,
          created_by_user_id: owner_scope.user.id
        })

      member_paste =
        Repo.insert!(%Paste{
          data: "member paste",
          workspace_id: workspace.id,
          created_by_user_id: member_scope.user.id
        })

      assert Pastes.manage_paste?(owner_scope, member_paste)
      assert Pastes.manage_paste?(member_scope, member_paste)
      refute Pastes.manage_paste?(member_scope, owner_paste)

      assert {:error, :not_found} = Pastes.delete_paste(member_scope, owner_paste)
      assert {:ok, _paste} = Pastes.delete_paste(owner_scope, member_paste)
      assert Repo.get(Paste, owner_paste.id)
      assert %Paste{removal_reason: "deleted"} = Repo.get(Paste, member_paste.id)
    end

    test "search_pastes/2 finds titles and inline content across joined workspaces", %{
      scope: scope
    } do
      {:ok, organization} =
        Organizations.create_organization(scope, %{name: "Search team", slug: "search-team"})

      [team_workspace] = organization.workspaces
      {:ok, team_scope} = Organizations.resolve_workspace_scope(scope, team_workspace)

      {:ok, by_title} =
        Pastes.create_paste(scope, %{title: "Nginx upstream notes", data: "body text"})

      {:ok, by_body} =
        Pastes.create_paste(team_scope, %{
          data: "first line\nthe NGINX worker crashed at 08:41 while reloading config"
        })

      {:ok, unrelated} = Pastes.create_paste(scope, %{data: "postgres vacuum"})
      {:ok, removed} = Pastes.create_paste(scope, %{data: "nginx but deleted"})
      {:ok, _} = Pastes.delete_paste(scope, removed)
      {:ok, _binary} = Pastes.create_paste(scope, %{data: <<0, "nginx", 255>>})

      outsider_scope = user_scope_fixture()
      {:ok, _hidden} = Pastes.create_paste(outsider_scope, %{data: "nginx elsewhere"})

      results = Pastes.search_pastes(scope, "  nginx ")
      ids = Enum.map(results, & &1.paste.id)

      assert Enum.sort(ids) == Enum.sort([by_title.id, by_body.id])
      refute unrelated.id in ids

      body_hit = Enum.find(results, &(&1.paste.id == by_body.id))
      assert body_hit.workspace.id == team_workspace.id
      assert body_hit.organization.id == organization.id
      assert {before, "NGINX", rest} = body_hit.excerpt
      assert before =~ "first line the "
      assert rest =~ "worker crashed"

      title_hit = Enum.find(results, &(&1.paste.id == by_title.id))
      assert title_hit.excerpt == nil
    end

    test "search_pastes/2 treats LIKE wildcards literally and ignores blank queries", %{
      scope: scope
    } do
      {:ok, percent} = Pastes.create_paste(scope, %{data: "cpu at 100% on node-3"})
      {:ok, _other} = Pastes.create_paste(scope, %{data: "cpu at 1000 on node_3"})

      assert [%{paste: %{id: id}}] = Pastes.search_pastes(scope, "100%")
      assert id == percent.id
      assert [_] = Pastes.search_pastes(scope, "node_3")
      assert Pastes.search_pastes(scope, "   ") == []
      assert Pastes.search_pastes(nil, "cpu") == []
    end

    test "removed pastes are listed with their reason and can be restored", %{scope: scope} do
      {:ok, deleted} = Pastes.create_paste(scope, %{data: "deleted one", expires_in: "1h"})
      {:ok, _} = Pastes.delete_paste(scope, deleted)
      expired = insert_paste!(scope, "expired one", DateTime.add(Paste.utc_now_ms(), -1, :day))

      moderated =
        scope
        |> insert_paste!("moderated one", nil)
        |> Ecto.Changeset.change(removed_at: Paste.utc_now_ms(), removal_reason: "moderated")
        |> Repo.update!()

      {:ok, active} = Pastes.create_paste(scope, %{data: "still here"})

      removed = Pastes.list_removed_pastes(scope)
      assert Enum.map(removed, & &1.id) |> Enum.sort() == Enum.sort([deleted.id, expired.id])
      assert Enum.find(removed, &(&1.id == deleted.id)).removed_by_user.id == scope.user.id
      assert Paste.removal_reason(Enum.find(removed, &(&1.id == expired.id))) == "expired"
      refute Enum.any?(removed, &(&1.id in [moderated.id, active.id]))

      assert %Paste{id: id} = Pastes.get_removed_paste(scope, deleted.id)
      assert id == deleted.id
      refute Pastes.get_removed_paste(scope, moderated.id)

      assert {:ok, restored} = Pastes.restore_paste(scope, deleted.id)
      assert restored.removed_at == nil and restored.removal_reason == nil
      assert DateTime.after?(restored.expires_at, DateTime.utc_now())
      assert Pastes.get_paste(scope, deleted.id)

      # An expired paste comes back without its expiry so it does not vanish again.
      assert {:ok, %Paste{expires_at: nil}} = Pastes.restore_paste(scope, expired.id)
      assert Pastes.get_paste(scope, expired.id)

      assert {:error, :not_found} = Pastes.restore_paste(scope, moderated.id)
      assert {:error, :not_found} = Pastes.restore_paste(scope, active.id)
    end

    test "only people who manage a paste can restore it or delete it now", %{scope: owner_scope} do
      member = user_fixture()
      organization = Organizations.get_personal_organization!(owner_scope.user)
      workspace = personal_workspace_fixture(owner_scope.user)
      {:ok, _} = Organizations.add_organization_member(owner_scope, organization, member)

      {:ok, member_scope} =
        Organizations.resolve_workspace_scope(user_scope_fixture(member), workspace)

      {:ok, owner_scope} = Organizations.resolve_workspace_scope(owner_scope, workspace)
      {:ok, paste} = Pastes.create_paste(owner_scope, %{data: "owner paste"})
      {:ok, _} = Pastes.delete_paste(owner_scope, paste)

      assert [%Paste{}] = Pastes.list_removed_pastes(member_scope)
      refute Pastes.get_removed_paste(member_scope, paste.id)
      assert {:error, :not_found} = Pastes.restore_paste(member_scope, paste.id)
      assert {:error, :not_found} = Pastes.purge_paste(member_scope, paste.id)
      assert Repo.get(Paste, paste.id)

      assert {:ok, _} = Pastes.purge_paste(owner_scope, paste.id)
      refute Repo.get(Paste, paste.id)
    end

    test "deleting an already removed paste is not found", %{scope: scope} do
      {:ok, paste} = Pastes.create_paste(scope, %{data: "once"})
      assert {:ok, _} = Pastes.delete_paste(scope, paste)
      assert {:error, :not_found} = Pastes.delete_paste(scope, paste)
    end

    test "purge_removed_pastes/1 waits out the recovery window, oldest first", %{
      scope: scope
    } do
      now = Paste.utc_now_ms()
      days_ago = fn days -> DateTime.add(now, -days, :day) end

      long_expired = insert_paste!(scope, "long expired", days_ago.(31))
      deleted_long_ago = remove!(insert_paste!(scope, "deleted long ago", nil), days_ago.(30))
      recently_expired = insert_paste!(scope, "recently expired", days_ago.(1))
      recently_deleted = remove!(insert_paste!(scope, "recently deleted", nil), days_ago.(2))
      active = insert_paste!(scope, "active", DateTime.add(now, 1, :hour))
      never_expires = insert_paste!(scope, "never", nil)

      assert Pastes.purge_removed_pastes(now: now, limit: 1) == 1
      refute Repo.get(Paste, long_expired.id)
      assert Repo.get(Paste, deleted_long_ago.id)

      assert Pastes.purge_removed_pastes(now: now, limit: 10) == 1
      refute Repo.get(Paste, deleted_long_ago.id)

      for kept <- [recently_expired, recently_deleted, active, never_expires] do
        assert Repo.get(Paste, kept.id)
      end
    end

    test "purge_removed_pastes/1 follows each workspace's recovery window", %{scope: scope} do
      workspace = personal_workspace_fixture(scope.user)

      {:ok, _workspace} =
        Organizations.change_workspace_settings(scope, workspace, %{recovery_window_days: 7})

      now = Paste.utc_now_ms()
      expired = insert_paste!(scope, "expired 8 days ago", DateTime.add(now, -8, :day))

      assert Pastes.purge_removed_pastes(now: now) == 1
      refute Repo.get(Paste, expired.id)
    end

    test "purge_removed_pastes/1 removes moderated pastes without a recovery window", %{
      scope: scope
    } do
      paste =
        scope
        |> insert_paste!("taken down", nil)
        |> Ecto.Changeset.change(removed_at: Paste.utc_now_ms(), removal_reason: "moderated")
        |> Repo.update!()

      assert Pastes.purge_removed_pastes() == 1
      refute Repo.get(Paste, paste.id)
    end

    test "purge_removed_pastes/1 rejects invalid batch limits" do
      assert_raise ArgumentError, ":limit must be a positive integer", fn ->
        Pastes.purge_removed_pastes(limit: 0)
      end
    end

    test "change_paste/3 returns a paste changeset", %{scope: scope} do
      assert %Ecto.Changeset{} = Pastes.change_paste(scope, %Paste{})
    end

    defp remove!(paste, removed_at) do
      paste
      |> Ecto.Changeset.change(removed_at: removed_at, removal_reason: "deleted")
      |> Repo.update!()
    end

    defp insert_paste!(scope, data, expires_at) do
      workspace = personal_workspace_fixture(scope.user)

      Repo.insert!(%Paste{
        data: data,
        syntax_highlight: "plain",
        audience: "workspace",
        workspace_id: workspace.id,
        created_by_user_id: scope.user.id,
        expires_at: expires_at
      })
    end
  end
end
