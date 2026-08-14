defmodule TextbinWeb.ApiV1.PasteController do
  use TextbinWeb, :controller

  alias Textbin.Accounts.Scope
  alias Textbin.Pastes
  alias Textbin.Pastes.Paste
  alias Textbin.Pastes.UploadCleaner

  require Logger

  # Keep raw upload reads small enough that an oversized request is rejected
  # after one bounded chunk instead of being accumulated in memory.
  @read_chunk_size 64_000

  # 1 MiB is the MVP safety limit when config does not provide
  # :max_paste_bytes.
  @default_max_paste_bytes 1_048_576

  def index(conn, _params) do
    with_api_scope(conn, fn current_scope ->
      pastes = Pastes.list_pastes(current_scope)
      render(conn, :index, pastes: pastes)
    end)
  end

  # Treat create as "store the request body as paste data" while still accepting
  # common JSON client shapes. This keeps CLI usage simple without making API
  # clients wrap data unless they want to.
  def create(conn, params) do
    case paste_attrs(conn, params) do
      {:ok, {:data, paste_attrs}, conn} ->
        create_paste(conn, paste_attrs)

      {:ok, {:file, path, metadata, paste_attrs}, conn} ->
        create_paste_from_file(conn, path, metadata, paste_attrs)

      {:error, :too_large, conn} ->
        render_too_large(conn, close?: true)

      {:error, {:spool, reason}, conn} ->
        Logger.error("Failed to spool paste upload: #{inspect(reason)}")
        render_upload_unavailable(conn)

      {:error, reason, conn} ->
        conn
        |> close_connection()
        |> put_status(:bad_request)
        |> json(%{errors: %{detail: "Could not read request body: #{inspect(reason)}"}})
    end
  end

  # Preferred JSON shape for API clients that already send objects.
  defp paste_attrs(conn, %{"data" => data} = params) when is_binary(data) do
    {:ok, {:data, build_paste_attrs(data, params)}, conn}
  end

  # Keep Phoenix generator-style wrapped params working for conventional clients
  # and tests.
  defp paste_attrs(conn, %{"paste" => %{"data" => data} = params}) when is_binary(data) do
    {:ok, {:data, build_paste_attrs(data, params)}, conn}
  end

  # Plug puts non-object JSON bodies, such as `"hello"`, under "_json". This is
  # useful for callers that want JSON content negotiation without an object
  # envelope.
  defp paste_attrs(conn, %{"_json" => data} = params) when is_binary(data) do
    {:ok, {:data, build_paste_attrs(data, params)}, conn}
  end

  # Non-JSON uploads keep the body unread after Plug.Parsers, so streamed
  # CLI/stdin data can be consumed here.
  defp paste_attrs(conn, params)
       when map_size(params) == 0 or is_map_key(params, "syntax_highlight") or
              is_map_key(params, "content_type") or
              is_map_key(params, "audience") or is_map_key(params, "visibility") or
              is_map_key(params, "expires_in") or is_map_key(params, "ttl") do
    case read_request_body(conn) do
      {:ok, path, metadata, conn} ->
        paste_attrs =
          params
          |> build_paste_attrs()
          |> Map.put_new("content_type", request_content_type(conn))

        {:ok, {:file, path, metadata, paste_attrs}, conn}

      {:error, reason, conn} ->
        {:error, reason, conn}
    end
  end

  # Let the changeset produce the canonical "data can't be blank" error for
  # unsupported payload shapes instead of inventing a separate controller error.
  defp paste_attrs(conn, _params) do
    {:ok, {:data, %{"data" => nil}}, conn}
  end

  defp build_paste_attrs(data, params) do
    %{"data" => data}
    |> put_paste_params(params)
  end

  defp build_paste_attrs(params) do
    put_paste_params(%{}, params)
  end

  defp put_paste_params(attrs, params) do
    attrs
    |> put_string_param(params, "content_type")
    |> put_string_param(params, "syntax_highlight")
    |> put_string_param(params, "audience")
    |> put_string_param(params, "visibility")
    |> put_string_param(params, "expires_in")
    |> put_string_param(params, "ttl")
  end

  defp put_string_param(attrs, params, key) do
    case params do
      %{^key => value} when is_binary(value) -> Map.put(attrs, key, value)
      _params -> attrs
    end
  end

  defp request_content_type(conn) do
    case get_req_header(conn, "content-type") do
      [content_type | _rest] -> content_type
      [] -> nil
    end
  end

  defp create_paste(conn, paste_params) do
    with_api_scope(conn, &create_scoped_paste(conn, &1, paste_params))
  end

  defp create_paste_from_file(conn, path, metadata, paste_params) do
    try do
      with_api_scope(
        conn,
        &insert_file_paste(conn, &1, path, metadata, paste_params)
      )
    after
      cleanup_spool(path)
    end
  end

  defp create_scoped_paste(conn, current_scope, paste_params) do
    case validate_paste_size(paste_params) do
      :ok -> insert_paste(conn, current_scope, paste_params)
      {:error, :too_large} -> render_too_large(conn)
    end
  end

  defp insert_paste(conn, current_scope, paste_params) do
    case Pastes.create_paste(current_scope, paste_params) do
      {:ok, paste} ->
        conn
        |> put_status(:created)
        |> put_resp_header("location", ~p"/api/v1/pastes/#{paste.id}")
        |> render(:create, paste: paste)

      {:error, changeset} ->
        render_changeset_errors(conn, changeset)
    end
  end

  defp insert_file_paste(conn, current_scope, path, metadata, paste_params) do
    case Pastes.create_paste_from_file(current_scope, path, metadata, paste_params) do
      {:ok, paste} ->
        conn
        |> put_status(:created)
        |> put_resp_header("location", ~p"/api/v1/pastes/#{paste.id}")
        |> render(:create, paste: paste)

      {:error, changeset} ->
        render_changeset_errors(conn, changeset)
    end
  end

  defp read_request_body(conn) do
    case prepare_upload_tmp_dir(upload_tmp_dir()) do
      :ok ->
        path = Path.join(upload_tmp_dir(), "textbin-upload-#{Ecto.UUID.generate()}")
        UploadCleaner.register_spool(path)
        open_request_body(conn, path)

      {:error, reason} ->
        {:error, {:spool, reason}, conn}
    end
  end

  defp open_request_body(conn, path) do
    try do
      result =
        File.open(path, [:write, :binary, :exclusive], fn file ->
          case File.chmod(path, 0o600) do
            :ok ->
              read_request_body(conn, file, :crypto.hash_init(:sha256), 0, max_paste_bytes())

            {:error, reason} ->
              {:error, {:spool, reason}, conn}
          end
        end)

      case result do
        {:ok, {:ok, metadata, conn}} ->
          {:ok, path, metadata, conn}

        {:ok, {:error, reason, conn}} ->
          cleanup_spool(path)
          {:error, reason, conn}

        {:error, reason} ->
          cleanup_spool(path)
          {:error, {:spool, reason}, conn}
      end
    rescue
      exception ->
        cleanup_spool(path)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        cleanup_spool(path)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp cleanup_spool(path) do
    File.rm(path)
    UploadCleaner.unregister_spool(path)
  end

  defp read_request_body(conn, file, hash, total_size, max_size) do
    case Plug.Conn.read_body(conn, length: @read_chunk_size, read_length: @read_chunk_size) do
      {:ok, chunk, conn} ->
        finalize_request_body(conn, file, hash, total_size, chunk, max_size)

      {:more, chunk, conn} ->
        continue_request_body(conn, file, hash, total_size, chunk, max_size)

      {:error, reason} ->
        {:error, {:request_body, reason}, conn}
    end
  end

  defp finalize_request_body(conn, file, hash, total_size, chunk, max_size) do
    with {:ok, hash, total_size} <- write_chunk(file, hash, total_size, chunk, max_size),
         :ok <- :file.sync(file) do
      metadata = %{size_bytes: total_size, sha256: :crypto.hash_final(hash)}
      {:ok, metadata, conn}
    else
      {:error, :too_large} -> {:error, :too_large, conn}
      {:error, {:spool, _reason} = error} -> {:error, error, conn}
      {:error, reason} -> {:error, {:spool, reason}, conn}
    end
  end

  defp continue_request_body(conn, file, hash, total_size, chunk, max_size) do
    case write_chunk(file, hash, total_size, chunk, max_size) do
      {:ok, hash, total_size} ->
        read_request_body(conn, file, hash, total_size, max_size)

      {:error, reason} ->
        {:error, reason, conn}
    end
  end

  defp write_chunk(file, hash, total_size, chunk, max_size) do
    total_size = total_size + byte_size(chunk)

    if total_size > max_size do
      {:error, :too_large}
    else
      case :file.write(file, chunk) do
        :ok -> {:ok, :crypto.hash_update(hash, chunk), total_size}
        {:error, reason} -> {:error, {:spool, reason}}
      end
    end
  end

  def show(conn, %{"id" => id}) do
    with_api_scope(conn, &show_scoped_paste(conn, &1, id))
  end

  defp show_scoped_paste(conn, current_scope, id) do
    with {:ok, paste_id} <- Ecto.UUID.cast(id),
         %{} = paste <- Pastes.get_paste(current_scope, paste_id) do
      render(conn, :show, paste: paste)
    else
      :error -> render_invalid_paste_id(conn)
      nil -> render_paste_not_found(conn)
    end
  end

  def delete(conn, %{"id" => id}) do
    with_api_scope(conn, fn current_scope ->
      result =
        with {:ok, paste_id} <- Ecto.UUID.cast(id) do
          Pastes.delete_personal_paste(current_scope, %Paste{id: paste_id})
        end

      case result do
        {:error, :not_found} ->
          send_resp(conn, :no_content, "")

        {:error, _reason} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{errors: %{detail: "Paste deletion could not be completed"}})

        _result ->
          send_resp(conn, :no_content, "")
      end
    end)
  end

  defp validate_paste_size(%{"data" => data}) when is_binary(data) do
    if byte_size(data) <= max_paste_bytes() do
      :ok
    else
      {:error, :too_large}
    end
  end

  defp validate_paste_size(_params), do: :ok

  defp render_too_large(conn, opts \\ []) do
    conn = if Keyword.get(opts, :close?, false), do: close_connection(conn), else: conn

    conn
    |> put_status(413)
    |> json(%{
      errors: %{
        detail: "Paste data exceeds the maximum size of #{max_paste_bytes()} bytes"
      }
    })
  end

  defp render_upload_unavailable(conn) do
    conn
    |> close_connection()
    |> put_status(:service_unavailable)
    |> json(%{errors: %{detail: "Paste upload is temporarily unavailable"}})
  end

  defp close_connection(conn) do
    if Plug.Conn.get_http_protocol(conn) in [:"HTTP/1.0", :"HTTP/1.1"] do
      put_resp_header(conn, "connection", "close")
    else
      conn
    end
  end

  defp prepare_upload_tmp_dir(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> File.chmod(path, 0o700)
      {:ok, _stat} -> {:error, :invalid_upload_tmp_dir}
      {:error, :enoent} -> path |> File.mkdir_p() |> then_chmod(path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp then_chmod(:ok, path), do: File.chmod(path, 0o700)
  defp then_chmod({:error, reason}, _path), do: {:error, reason}

  defp render_invalid_paste_id(conn) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "Paste id must be a valid UUID"}})
  end

  defp render_paste_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: "Paste not found"}})
  end

  defp render_changeset_errors(conn, changeset) do
    changeset = maybe_alias_legacy_visibility_errors(changeset, conn.params)

    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: TextbinWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  defp maybe_alias_legacy_visibility_errors(changeset, params) do
    params = Map.get(params, "paste", params)

    if is_map(params) and Map.has_key?(params, "visibility") and
         not Map.has_key?(params, "audience") do
      errors =
        Enum.map(changeset.errors, fn
          {:audience, error} -> {:visibility, error}
          error -> error
        end)

      %{changeset | errors: errors}
    else
      changeset
    end
  end

  defp max_paste_bytes do
    Application.get_env(:textbin, :max_paste_bytes, @default_max_paste_bytes)
  end

  defp upload_tmp_dir do
    Application.get_env(:textbin, :upload_tmp_dir, System.tmp_dir!())
  end

  defp with_api_scope(%{assigns: %{current_scope: %Scope{user: %{}} = current_scope}}, fun) do
    fun.(current_scope)
  end

  defp with_api_scope(conn, _fun),
    do:
      conn
      |> put_status(:unauthorized)
      |> json(%{errors: %{detail: "API token required"}})
end
