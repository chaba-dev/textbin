defmodule TextbinWeb.ApiV1.PasteControllerTest do
  use TextbinWeb.ConnCase, async: false

  alias Textbin.Accounts
  alias Textbin.Accounts.UserToken
  alias Textbin.Organizations
  alias Textbin.Pastes
  alias Textbin.Pastes.Paste
  alias Textbin.Repo
  alias Textbin.Storage

  import ExUnit.CaptureLog
  import Textbin.AccountsFixtures

  @max_paste_bytes 1_048_576
  @create_attrs %{data: "some data", syntax_highlight: "elixir"}
  @invalid_attrs %{data: nil}

  setup %{conn: conn} do
    user = user_fixture()
    scope = user_scope_fixture(user)
    {:ok, {token, user_token}} = Accounts.create_user_api_token(user, %{"name" => "CLI"})

    %{
      conn: put_req_header(conn, "authorization", "Bearer #{token}"),
      scope: scope,
      user_token: user_token
    }
  end

  describe "index" do
    test "lists scoped pastes", %{conn: conn, scope: scope} do
      {:ok, paste} = Pastes.create_paste(scope, %{data: "some data"})
      {:ok, _other_paste} = Pastes.create_paste(user_scope_fixture(), %{data: "other data"})

      conn = get(conn, ~p"/api/v1/pastes")

      assert conn.private.phoenix_controller == TextbinWeb.ApiV1.PasteController
      assert conn.private.phoenix_view["json"] == TextbinWeb.ApiV1.PasteJSON
      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["id"] == paste.id
      assert data["data"] == "some data"
      assert data["syntax_highlight"] == "plain"
      assert data["visibility"] == "private"
    end

    test "requires an API token", %{conn: _conn} do
      conn = get(build_conn(), ~p"/api/v1/pastes")

      assert %{"errors" => %{"detail" => "API token required"}} = json_response(conn, 401)
    end
  end

  describe "create paste" do
    test "renders paste when data is valid", %{conn: conn, scope: scope} do
      conn = post(conn, ~p"/api/v1/pastes", paste: @create_attrs)

      assert %{
               "id" => id,
               "syntax_highlight" => "elixir",
               "visibility" => "private",
               "expires_at" => expires_at
             } =
               response_data = json_response(conn, 201)["data"]

      refute Map.has_key?(response_data, "data")
      assert is_nil(expires_at)
      assert_stored_paste(scope, id, "some data", "elixir")

      conn = get(conn, ~p"/api/v1/pastes/#{id}")

      assert %{
               "id" => ^id,
               "data" => "some data",
               "syntax_highlight" => "elixir",
               "visibility" => "private",
               "expires_at" => show_expires_at,
               "inserted_at" => inserted_at,
               "updated_at" => updated_at
             } = json_response(conn, 200)["data"]

      assert show_expires_at == expires_at
      assert is_nil(show_expires_at)
      assert_millisecond_timestamp(inserted_at)
      assert_millisecond_timestamp(updated_at)
    end

    test "renders paste from flat JSON data", %{conn: conn, scope: scope} do
      conn = post(conn, ~p"/api/v1/pastes", @create_attrs)

      assert %{"id" => id, "syntax_highlight" => "elixir", "expires_at" => expires_at} =
               response_data = json_response(conn, 201)["data"]

      refute Map.has_key?(response_data, "data")
      assert is_nil(expires_at)
      assert_stored_paste(scope, id, "some data", "elixir")
    end

    test "renders paste from JSON string body", %{conn: conn, scope: scope} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/pastes", Jason.encode!("json string data"))

      assert %{"id" => id} = response_data = json_response(conn, 201)["data"]
      assert response_data["syntax_highlight"] == "plain"
      assert is_nil(response_data["expires_at"])
      refute Map.has_key?(response_data, "data")
      assert_stored_paste(scope, id, "json string data", "plain")
    end

    test "renders paste from raw request body", %{conn: conn, scope: scope} do
      upload_tmp_dir = put_upload_tmp_dir()

      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post(~p"/api/v1/pastes", "streamed data")

      assert %{"id" => id} = response_data = json_response(conn, 201)["data"]
      assert response_data["syntax_highlight"] == "plain"
      assert is_nil(response_data["expires_at"])
      refute Map.has_key?(response_data, "data")
      assert_stored_paste(scope, id, "streamed data", "plain")

      paste = Pastes.get_paste!(scope, id)
      assert paste.size_bytes == byte_size("streamed data")
      assert paste.sha256 == :crypto.hash(:sha256, "streamed data")

      assert {:ok, %{mode: mode}} = File.stat(upload_tmp_dir)
      assert Bitwise.band(mode, 0o777) == 0o700
      assert File.ls!(upload_tmp_dir) == []
    end

    test "renders paste from raw request body with syntax highlight", %{conn: conn, scope: scope} do
      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post(~p"/api/v1/pastes?syntax_highlight=elixir", "streamed data")

      assert %{"id" => id, "syntax_highlight" => "elixir", "expires_at" => expires_at} =
               response_data = json_response(conn, 201)["data"]

      refute Map.has_key?(response_data, "data")
      assert is_nil(expires_at)
      assert_stored_paste(scope, id, "streamed data", "elixir")
    end

    test "keeps a small raw body containing NUL in blob storage", %{conn: conn, scope: scope} do
      data = <<"binary", 0, "paste">>

      conn =
        conn
        |> put_req_header("content-type", "application/octet-stream")
        |> post(~p"/api/v1/pastes", data)

      assert %{"id" => id} = json_response(conn, 201)["data"]
      paste = Pastes.get_paste!(scope, id)
      assert paste.data == data
      assert paste.storage_key == "pastes/#{paste.id}"
      assert paste.content_type == "application/octet-stream"

      conn = get(conn, ~p"/api/v1/pastes/#{paste.id}")

      assert %{
               "content_type" => "application/octet-stream",
               "data" => nil,
               "data_base64" => encoded,
               "data_encoding" => "base64"
             } = json_response(conn, 200)["data"]

      assert Base.decode64!(encoded) == data
    end

    test "normalizes and stores the raw request content type", %{conn: conn, scope: scope} do
      conn =
        conn
        |> put_req_header("content-type", "text/html; charset=iso-8859-1")
        |> post(~p"/api/v1/pastes", "<strong>source</strong>")

      assert %{"id" => id, "content_type" => "text/html"} =
               json_response(conn, 201)["data"]

      assert Pastes.get_paste!(scope, id).content_type == "text/html"
    end

    test "accepts an explicit content type in JSON", %{conn: conn, scope: scope} do
      conn =
        post(conn, ~p"/api/v1/pastes", %{
          data: "fn main() {}",
          content_type: "text/x-rust"
        })

      assert %{"id" => id, "content_type" => "text/x-rust"} =
               json_response(conn, 201)["data"]

      assert Pastes.get_paste!(scope, id).content_type == "text/x-rust"
    end

    test "returns a validation error for a content type exceeding the database limit", %{
      conn: conn
    } do
      content_type = "application/" <> String.duplicate("a", 244)

      conn =
        conn
        |> put_req_header("content-type", content_type)
        |> post(~p"/api/v1/pastes", "content")

      assert %{"content_type" => ["should be at most 255 character(s)"]} =
               json_response(conn, 422)["errors"]
    end

    test "stores and returns every registered-user visibility", %{conn: conn, scope: scope} do
      for visibility <- ["private", "unlisted", "public"] do
        conn = post(conn, ~p"/api/v1/pastes", %{data: visibility, visibility: visibility})

        assert %{"id" => id, "visibility" => ^visibility} = json_response(conn, 201)["data"]
        expected_audience = if visibility == "private", do: "workspace", else: visibility
        assert Pastes.get_paste!(scope, id).audience == expected_audience
      end
    end

    test "accepts visibility for raw request bodies", %{conn: conn, scope: scope} do
      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post(~p"/api/v1/pastes?visibility=public", "public streamed data")

      assert %{"id" => id, "visibility" => "public"} = json_response(conn, 201)["data"]
      assert Pastes.get_paste!(scope, id).audience == "public"
    end

    test "accepts and returns the audience concept", %{conn: conn, scope: scope} do
      conn = post(conn, ~p"/api/v1/pastes", %{data: "members", audience: "workspace"})

      assert %{
               "id" => id,
               "audience" => "workspace",
               "visibility" => "private"
             } = json_response(conn, 201)["data"]

      assert Pastes.get_paste!(scope, id).audience == "workspace"
    end

    test "uses the user's default expiration", %{conn: conn, scope: scope} do
      {:ok, _user} =
        Accounts.update_user_paste_defaults(scope.user, %{default_paste_ttl: "30d"})

      conn = post(conn, ~p"/api/v1/pastes", paste: @create_attrs)

      assert %{"id" => id, "expires_at" => expires_at} = json_response(conn, 201)["data"]
      assert_millisecond_timestamp(expires_at)

      paste = Pastes.get_paste!(scope, id)
      assert DateTime.diff(paste.expires_at, DateTime.utc_now(), :second) in 2_591_990..2_592_000
    end

    test "renders paste from raw request body with expiration", %{conn: conn, scope: scope} do
      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post(~p"/api/v1/pastes?expires_in=1h", "streamed data")

      assert %{"id" => id, "expires_at" => expires_at} =
               response_data = json_response(conn, 201)["data"]

      refute Map.has_key?(response_data, "data")
      assert_millisecond_timestamp(expires_at)

      paste = Pastes.get_paste!(scope, id)
      assert DateTime.diff(paste.expires_at, DateTime.utc_now(), :second) in 3590..3600
    end

    test "accepts a valid API bearer token", %{conn: conn, scope: scope, user_token: user_token} do
      conn = post(conn, ~p"/api/v1/pastes", paste: @create_attrs)

      assert %{"id" => id} = json_response(conn, 201)["data"]
      assert_stored_paste(scope, id, "some data", "elixir")
      assert %{last_used_at: %DateTime{}} = Textbin.Repo.get!(UserToken, user_token.id)
    end

    test "rejects an invalid API bearer token" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer txb_invalid")
        |> post(~p"/api/v1/pastes", paste: @create_attrs)

      assert %{"errors" => %{"detail" => "Invalid API token"}} = json_response(conn, 401)
    end

    test "rejects a malformed authorization header" do
      conn =
        build_conn()
        |> put_req_header("authorization", "Token invalid")
        |> post(~p"/api/v1/pastes", paste: @create_attrs)

      assert %{"errors" => %{"detail" => "Invalid authorization header"}} =
               json_response(conn, 401)
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/pastes", paste: @invalid_attrs)

      assert %{"data" => [_]} = json_response(conn, 422)["errors"]
    end

    test "renders errors when expiration is invalid", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/pastes", paste: Map.put(@create_attrs, :expires_in, "forever"))

      assert %{"expires_at" => ["must use one of: never, 10m, 1h, 6h, 12h, 1d, 7d, 30d"]} =
               json_response(conn, 422)["errors"]
    end

    test "renders errors when visibility is invalid", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/pastes", Map.put(@create_attrs, :visibility, "secret"))

      assert %{"visibility" => ["is invalid"]} = json_response(conn, 422)["errors"]
    end

    test "rejects JSON data over the configured size limit", %{conn: conn} do
      too_large_data = String.duplicate("a", @max_paste_bytes + 1)

      conn = post(conn, ~p"/api/v1/pastes", %{data: too_large_data})

      assert %{
               "errors" => %{
                 "detail" => "Paste data exceeds the maximum size of 1048576 bytes"
               }
             } = json_response(conn, 413)
    end

    test "rejects raw request bodies over the configured size limit", %{conn: conn} do
      upload_tmp_dir = put_upload_tmp_dir()
      too_large_data = String.duplicate("a", @max_paste_bytes + 1)

      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post(~p"/api/v1/pastes", too_large_data)

      assert %{
               "errors" => %{
                 "detail" => "Paste data exceeds the maximum size of 1048576 bytes"
               }
             } = json_response(conn, 413)

      assert get_resp_header(conn, "connection") == ["close"]
      assert File.ls!(upload_tmp_dir) == []
    end

    test "does not send a connection header when rejecting an HTTP/2 upload", %{conn: conn} do
      too_large_data = String.duplicate("a", @max_paste_bytes + 1)
      {adapter, payload} = conn.adapter
      conn = %{conn | adapter: {adapter, %{payload | http_protocol: :"HTTP/2"}}}

      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post(~p"/api/v1/pastes", too_large_data)

      assert json_response(conn, 413)
      assert get_resp_header(conn, "connection") == []
    end

    test "reports an unavailable upload directory as a server failure", %{conn: conn} do
      blocked_path =
        Path.join(System.tmp_dir!(), "textbin-upload-blocked-#{Ecto.UUID.generate()}")

      File.write!(blocked_path, "not a directory")
      put_upload_tmp_dir(blocked_path)
      on_exit(fn -> File.rm(blocked_path) end)

      capture_log(fn ->
        conn =
          conn
          |> put_req_header("content-type", "text/plain")
          |> post(~p"/api/v1/pastes", "cannot be spooled")

        assert %{"errors" => %{"detail" => "Paste upload is temporarily unavailable"}} =
                 json_response(conn, 503)

        assert get_resp_header(conn, "connection") == ["close"]
      end)
    end

    test "removes the upload file when storage fails", %{conn: conn} do
      upload_tmp_dir = put_upload_tmp_dir()
      blocked_root = Path.join(System.tmp_dir!(), "textbin-blocked-#{Ecto.UUID.generate()}")
      File.write!(blocked_root, "not a directory")
      put_storage_config(adapter: Textbin.Storage.Local, opts: [root: blocked_root])
      on_exit(fn -> File.rm(blocked_root) end)

      capture_log(fn ->
        data = String.duplicate("a", 8_193)

        conn =
          conn
          |> put_req_header("content-type", "text/plain")
          |> post(~p"/api/v1/pastes", data)

        assert %{"data" => ["could not be stored"]} = json_response(conn, 422)["errors"]
      end)

      assert File.ls!(upload_tmp_dir) == []
    end

    test "uses the configured size limit", %{conn: conn} do
      put_max_paste_bytes(4)

      conn = post(conn, ~p"/api/v1/pastes", %{data: "12345"})

      assert %{
               "errors" => %{
                 "detail" => "Paste data exceeds the maximum size of 4 bytes"
               }
             } = json_response(conn, 413)
    end
  end

  describe "show paste" do
    test "returns bad request when id is not a UUID", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/pastes/not-a-uuid")

      assert %{
               "errors" => %{
                 "detail" => "Paste id must be a valid UUID"
               }
             } = json_response(conn, 400)
    end

    test "returns not found when paste does not exist", %{conn: conn} do
      missing_id = "00000000-0000-0000-0000-000000000000"

      conn = get(conn, ~p"/api/v1/pastes/#{missing_id}")

      assert %{
               "errors" => %{
                 "detail" => "Paste not found"
               }
             } = json_response(conn, 404)
    end
  end

  describe "update paste" do
    test "is not routable", %{conn: conn, scope: scope} do
      {:ok, paste} = Pastes.create_paste(scope, %{data: "some data"})

      conn = patch(conn, ~p"/api/v1/pastes/#{paste.id}", paste: %{data: "updated data"})

      assert response(conn, 404)
      assert_stored_paste(scope, paste.id, "some data", "plain")
    end
  end

  describe "delete paste" do
    test "deletes chosen paste", %{conn: conn, scope: scope} do
      {:ok, paste} = Pastes.create_paste(scope, %{data: "some data"})

      conn = delete(conn, ~p"/api/v1/pastes/#{paste.id}")

      assert response(conn, 204)
      assert_raise Ecto.NoResultsError, fn -> Pastes.get_paste!(scope, paste.id) end
    end

    test "deletes a blob without reading it", %{conn: conn, scope: scope} do
      original_storage = Application.fetch_env!(:textbin, Storage)
      original_inline_bytes = Application.fetch_env!(:textbin, :inline_paste_bytes)

      Application.put_env(:textbin, Storage,
        adapter: Textbin.DeleteOnlyStorage,
        opts: [test_pid: self(), delegate: original_storage]
      )

      Application.put_env(:textbin, :inline_paste_bytes, 0)

      on_exit(fn ->
        Application.put_env(:textbin, Storage, original_storage)
        Application.put_env(:textbin, :inline_paste_bytes, original_inline_bytes)
      end)

      {:ok, paste} = Pastes.create_paste(scope, %{data: "delete without read"})

      conn = delete(conn, ~p"/api/v1/pastes/#{paste.id}")

      assert response(conn, 204)
      assert_receive {:storage_deleted, storage_key}
      assert storage_key == paste.storage_key
      refute_received {:unexpected_storage_get, _storage_key}
      refute Textbin.Repo.get(Textbin.Pastes.Paste, paste.id)
    end

    test "does not delete another user's paste", %{conn: conn} do
      other_scope = user_scope_fixture()
      {:ok, paste} = Pastes.create_paste(other_scope, %{data: "other user data"})

      conn = delete(conn, ~p"/api/v1/pastes/#{paste.id}")

      assert response(conn, 204)
      assert Pastes.get_paste!(other_scope, paste.id)
    end

    test "does not delete a paste from a team workspace", %{conn: conn, scope: scope} do
      {:ok, organization} =
        Organizations.create_organization(scope, %{name: "API team", slug: "api-team"})

      [workspace] = organization.workspaces

      paste =
        Repo.insert!(%Paste{
          data: "team paste",
          workspace_id: workspace.id,
          created_by_user_id: scope.user.id
        })

      conn = delete(conn, ~p"/api/v1/pastes/#{paste.id}")

      assert response(conn, 204)
      assert Repo.get(Paste, paste.id)
    end

    test "returns no content when id is not a UUID", %{conn: conn} do
      conn = delete(conn, ~p"/api/v1/pastes/not-a-uuid")

      assert response(conn, 204) == ""
    end

    test "returns no content when paste does not exist", %{conn: conn} do
      missing_id = "00000000-0000-0000-0000-000000000000"

      conn = delete(conn, ~p"/api/v1/pastes/#{missing_id}")

      assert response(conn, 204) == ""
    end

    test "returns no content when the paste was already deleted", %{conn: conn, scope: scope} do
      {:ok, paste} = Pastes.create_paste(scope, %{data: "delete twice"})

      assert response(delete(conn, ~p"/api/v1/pastes/#{paste.id}"), 204) == ""
      assert response(delete(conn, ~p"/api/v1/pastes/#{paste.id}"), 204) == ""
    end
  end

  defp assert_millisecond_timestamp(timestamp) do
    assert timestamp =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/
  end

  defp assert_stored_paste(scope, id, expected_data, expected_syntax_highlight) do
    paste = Pastes.get_paste!(scope, id)

    assert paste.data == expected_data
    assert paste.syntax_highlight == expected_syntax_highlight
  end

  defp put_max_paste_bytes(max_paste_bytes) do
    previous_max_paste_bytes = Application.get_env(:textbin, :max_paste_bytes)
    Application.put_env(:textbin, :max_paste_bytes, max_paste_bytes)

    on_exit(fn ->
      restore_application_env(:max_paste_bytes, previous_max_paste_bytes)
    end)
  end

  defp put_upload_tmp_dir(upload_tmp_dir \\ nil) do
    upload_tmp_dir =
      upload_tmp_dir || Path.join(System.tmp_dir!(), "textbin-uploads-#{Ecto.UUID.generate()}")

    previous_upload_tmp_dir = Application.get_env(:textbin, :upload_tmp_dir)
    Application.put_env(:textbin, :upload_tmp_dir, upload_tmp_dir)

    on_exit(fn ->
      restore_application_env(:upload_tmp_dir, previous_upload_tmp_dir)
      File.rm_rf!(upload_tmp_dir)
    end)

    upload_tmp_dir
  end

  defp put_storage_config(config) do
    previous_config = Application.fetch_env!(:textbin, Storage)
    Application.put_env(:textbin, Storage, config)
    on_exit(fn -> Application.put_env(:textbin, Storage, previous_config) end)
  end

  defp restore_application_env(key, nil), do: Application.delete_env(:textbin, key)
  defp restore_application_env(key, value), do: Application.put_env(:textbin, key, value)
end
