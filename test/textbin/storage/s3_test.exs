defmodule Textbin.Storage.S3Test do
  use ExUnit.Case, async: true

  alias Textbin.Storage.S3

  @base_opts [
    endpoint: "http://object-storage:8333",
    bucket: "textbin",
    region: "us-east-1",
    access_key_id: "access-key",
    secret_access_key: "secret-key"
  ]

  test "puts content with a signed path-style request" do
    parent = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, conn.method, conn.request_path, conn.req_headers, body})
      Plug.Conn.send_resp(conn, 200, "")
    end

    opts = Keyword.put(@base_opts, :req_options, plug: plug)
    data = "stored in s3"

    assert {:ok, metadata} = S3.put("pastes/id", data, opts)
    assert metadata.size_bytes == byte_size(data)
    assert metadata.sha256 == :crypto.hash(:sha256, data)

    assert_receive {:request, "PUT", "/textbin/pastes/id", headers, ^data}

    assert {"authorization", "AWS4-HMAC-SHA256 " <> _signature} =
             List.keyfind(headers, "authorization", 0)
  end

  test "streams a file with its fixed content length" do
    parent = self()
    path = Path.join(System.tmp_dir!(), "textbin-s3-upload-#{Ecto.UUID.generate()}")
    data = String.duplicate("streamed to s3\n", 8_000)
    metadata = %{size_bytes: byte_size(data), sha256: :crypto.hash(:sha256, data)}
    File.write!(path, data)
    on_exit(fn -> File.rm(path) end)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:request, conn.req_headers, body})
      Plug.Conn.send_resp(conn, 200, "")
    end

    opts = Keyword.put(@base_opts, :req_options, plug: plug)

    assert S3.put_file("pastes/file", path, metadata, opts) == {:ok, metadata}
    assert_receive {:request, headers, ^data}
    assert {"content-length", content_length} = List.keyfind(headers, "content-length", 0)
    assert content_length == Integer.to_string(byte_size(data))

    assert {"x-amz-content-sha256", payload_sha256} =
             List.keyfind(headers, "x-amz-content-sha256", 0)

    assert payload_sha256 == Base.encode16(metadata.sha256, case: :lower)
  end

  test "rejects mismatched file metadata before sending a request" do
    path = Path.join(System.tmp_dir!(), "textbin-s3-upload-#{Ecto.UUID.generate()}")
    data = "same-size metadata mismatch"
    metadata = %{size_bytes: byte_size(data), sha256: :crypto.hash(:sha256, "x" <> data)}
    File.write!(path, data)
    on_exit(fn -> File.rm(path) end)

    opts =
      Keyword.put(@base_opts, :req_options,
        plug: fn _conn -> flunk("mismatched content must not be uploaded") end
      )

    assert S3.put_file("pastes/mismatch", path, metadata, opts) ==
             {:error, :metadata_mismatch}
  end

  test "gets content and maps missing objects" do
    content_opts =
      Keyword.put(@base_opts, :req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 200, "object data") end
      )

    missing_opts =
      Keyword.put(@base_opts, :req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 404, "missing") end
      )

    assert S3.get("pastes/id", content_opts) == {:ok, "object data"}
    assert S3.get("pastes/missing", missing_opts) == {:error, :enoent}
  end

  test "deletes content idempotently" do
    opts =
      Keyword.put(@base_opts, :req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 204, "") end
      )

    assert :ok = S3.delete("pastes/id", opts)
  end

  test "does not mistake a missing bucket for a deleted object" do
    opts =
      Keyword.put(@base_opts, :req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 404, "missing bucket") end
      )

    assert S3.delete("pastes/id", opts) == {:error, {:http_status, 404}}
  end

  test "returns non-success statuses without exposing response bodies" do
    opts =
      Keyword.put(@base_opts, :req_options,
        plug: fn conn -> Plug.Conn.send_resp(conn, 503, "provider details") end,
        retry: false
      )

    assert S3.put("pastes/id", "data", opts) == {:error, {:http_status, 503}}
  end
end
