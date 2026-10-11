defmodule TextbinWeb.ApiV1.PasteController do
  use TextbinWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import TextbinWeb.ApiDocs

  alias Textbin.Accounts.Scope
  alias Textbin.Organizations
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

  tags ["Pastes"]

  # Every paste operation exists twice: for the caller's personal workspace,
  # and under /workspaces/{workspace_id}. The workspace_* actions share the
  # personal actions' behaviour and spec; the workspace_id path parameter is
  # what selects the scope.
  @index_spec [
    operation_id: "listPastes",
    summary: "List pastes in your personal workspace",
    responses: with_scope_errors(%{200 => response("Pastes, newest first", "PasteList")})
  ]

  @create_spec [
    operation_id: "createPaste",
    summary: "Create a paste in your personal workspace",
    description:
      "Send JSON, or send the content itself as the request body (any other content type) with the fields as query parameters.",
    parameters: paste_field_parameters(),
    request_body: create_paste_body(),
    responses:
      with_scope_errors(%{
        201 => response("The new paste, without its content", "PasteMetadataResponse"),
        400 => error("The request body could not be read"),
        413 => error("The content is larger than the server allows"),
        422 => response("Rejected fields", "ValidationError"),
        503 => error("Paste storage is temporarily unavailable")
      })
  ]

  @show_spec [
    operation_id: "getPaste",
    summary: "Show a paste with its content",
    parameters: [id: uuid_path("Paste id")],
    responses:
      with_scope_errors(%{
        200 => response("The paste", "PasteResponse"),
        400 => error("The id is not a UUID"),
        404 => error("Paste or workspace not found")
      })
  ]

  @delete_spec [
    operation_id: "deletePaste",
    summary: "Delete a paste; it stays restorable for the workspace's recovery window",
    parameters: [id: uuid_path("Paste id")],
    responses:
      with_scope_errors(%{
        204 => no_content("Deleted, or nothing to delete"),
        503 => error("The deletion could not be completed")
      })
  ]

  @deleted_spec [
    operation_id: "listRemovedPastes",
    summary: "List deleted and expired pastes that can still be restored",
    responses: with_scope_errors(%{200 => response("Restorable pastes", "RemovedPasteList")})
  ]

  @restore_spec [
    operation_id: "restorePaste",
    summary: "Restore a deleted or expired paste",
    parameters: [id: uuid_path("Paste id")],
    responses:
      with_scope_errors(%{
        200 => response("The restored paste, without its content", "PasteMetadataResponse"),
        400 => error("The id is not a UUID"),
        404 => error("No restorable paste you can manage has this id")
      })
  ]

  @purge_spec [
    operation_id: "purgePaste",
    summary: "Delete a removed paste for good",
    parameters: [id: uuid_path("Paste id")],
    responses:
      with_scope_errors(%{
        204 => no_content("Deleted for good"),
        400 => error("The id is not a UUID"),
        404 => error("No removed paste you can manage has this id"),
        503 => error("The stored content could not be deleted; try again")
      })
  ]

  operation :workspace_index, in_workspace(@index_spec)
  def workspace_index(conn, params), do: index(conn, params)

  operation :workspace_create, in_workspace(@create_spec)
  def workspace_create(conn, params), do: create(conn, params)

  operation :workspace_show, in_workspace(@show_spec)
  def workspace_show(conn, params), do: show(conn, params)

  operation :workspace_delete, in_workspace(@delete_spec)
  def workspace_delete(conn, params), do: delete(conn, params)

  operation :workspace_deleted, in_workspace(@deleted_spec)
  def workspace_deleted(conn, params), do: deleted(conn, params)

  operation :workspace_restore, in_workspace(@restore_spec)
  def workspace_restore(conn, params), do: restore(conn, params)

  operation :workspace_purge, in_workspace(@purge_spec)
  def workspace_purge(conn, params), do: purge(conn, params)

  operation :index, @index_spec

  def index(conn, params) do
    with_paste_scope(conn, params, fn paste_scope ->
      case Pastes.list_pastes_with_access(paste_scope) do
        {:ok, pastes} ->
          render(conn, :index,
            pastes: pastes,
            organization_id: paste_scope.organization.id,
            workspace_id: paste_scope.workspace.id
          )

        {:error, :not_found} ->
          render_workspace_not_found(conn)
      end
    end)
  end

  # Treat create as "store the request body as paste data" while still accepting
  # common JSON client shapes. This keeps CLI usage simple without making API
  # clients wrap data unless they want to.
  operation :create, @create_spec

  def create(conn, params) do
    request_params = Map.drop(params, Map.keys(conn.path_params))

    case paste_attrs(conn, request_params) do
      {:ok, {:data, paste_attrs}, conn} ->
        create_paste(conn, params, paste_attrs)

      {:ok, {:file, path, metadata, paste_attrs}, conn} ->
        create_paste_from_file(conn, params, path, metadata, paste_attrs)

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
  defp paste_attrs(conn, params) do
    metadata_keys =
      ~w(title reference_url syntax_highlight content_type audience visibility expires_in ttl)

    if map_size(params) == 0 or Enum.any?(metadata_keys, &Map.has_key?(params, &1)) do
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
    else
      # Let the changeset produce the canonical "data can't be blank" error for
      # unsupported payload shapes instead of inventing a separate controller error.
      {:ok, {:data, %{"data" => nil}}, conn}
    end
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
    |> put_string_param(params, "title")
    |> put_string_param(params, "reference_url")
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

  defp create_paste(conn, route_params, paste_params) do
    with_paste_scope(conn, route_params, &create_scoped_paste(conn, &1, paste_params))
  end

  defp create_paste_from_file(conn, route_params, path, metadata, paste_params) do
    try do
      with_paste_scope(
        conn,
        route_params,
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
        |> put_resp_header("location", paste_location(conn, current_scope, paste))
        |> render(:create,
          paste: paste,
          organization_id: current_scope.organization.id,
          workspace_id: current_scope.workspace.id
        )

      {:error, :not_found} ->
        render_workspace_not_found(conn)

      {:error, changeset} ->
        render_changeset_errors(conn, changeset)
    end
  end

  defp insert_file_paste(conn, current_scope, path, metadata, paste_params) do
    case Pastes.create_paste_from_file(current_scope, path, metadata, paste_params) do
      {:ok, paste} ->
        conn
        |> put_status(:created)
        |> put_resp_header("location", paste_location(conn, current_scope, paste))
        |> render(:create,
          paste: paste,
          organization_id: current_scope.organization.id,
          workspace_id: current_scope.workspace.id
        )

      {:error, :not_found} ->
        render_workspace_not_found(conn)

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

  operation :show, @show_spec

  def show(conn, %{"id" => id} = params) do
    with_paste_scope(conn, params, &show_scoped_paste(conn, &1, id))
  end

  defp show_scoped_paste(conn, current_scope, id) do
    with {:ok, paste_id} <- Ecto.UUID.cast(id),
         %{} = paste <- Pastes.get_paste(current_scope, paste_id) do
      render(conn, :show,
        paste: paste,
        organization_id: current_scope.organization.id,
        workspace_id: current_scope.workspace.id
      )
    else
      :error -> render_invalid_paste_id(conn)
      nil -> render_paste_not_found(conn)
    end
  end

  operation :delete, @delete_spec

  def delete(conn, %{"id" => id} = params) do
    with_paste_scope(conn, params, fn current_scope ->
      result =
        with {:ok, paste_id} <- Ecto.UUID.cast(id) do
          delete_scoped_paste(current_scope, %Paste{id: paste_id}, params)
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

  defp delete_scoped_paste(scope, paste, %{"workspace_id" => _workspace_id}),
    do: Pastes.delete_paste(scope, paste)

  defp delete_scoped_paste(scope, paste, _params),
    do: Pastes.delete_personal_paste(scope, paste)

  operation :deleted, @deleted_spec

  def deleted(conn, params) do
    with_paste_scope(conn, params, fn scope ->
      render(conn, :deleted,
        pastes: Pastes.list_removed_pastes(scope),
        organization_id: scope.organization.id,
        workspace_id: scope.workspace.id,
        recovery_window_days: scope.workspace.recovery_window_days
      )
    end)
  end

  # Restoring and deleting for good answer 404 alike for an unknown id, a paste
  # the caller cannot manage, and one whose recovery window has passed, so the
  # response never confirms another member's paste exists.
  operation :restore, @restore_spec

  def restore(conn, %{"id" => id} = params) do
    with_paste_scope(conn, params, fn scope ->
      with {:ok, paste_id} <- Ecto.UUID.cast(id),
           {:ok, paste} <- Pastes.restore_paste(scope, paste_id) do
        render(conn, :restored,
          paste: paste,
          organization_id: scope.organization.id,
          workspace_id: scope.workspace.id
        )
      else
        :error -> render_invalid_paste_id(conn)
        {:error, _reason} -> render_removed_paste_not_found(conn)
      end
    end)
  end

  operation :purge, @purge_spec

  def purge(conn, %{"id" => id} = params) do
    with_paste_scope(conn, params, fn scope ->
      with {:ok, paste_id} <- Ecto.UUID.cast(id),
           {:ok, _paste} <- Pastes.purge_paste(scope, paste_id) do
        send_resp(conn, :no_content, "")
      else
        :error ->
          render_invalid_paste_id(conn)

        {:error, :not_found} ->
          render_removed_paste_not_found(conn)

        {:error, _reason} ->
          conn
          |> put_status(:service_unavailable)
          |> json(%{errors: %{detail: "Paste could not be permanently deleted"}})
      end
    end)
  end

  defp render_removed_paste_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: "Removed paste not found"}})
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

  defp with_paste_scope(conn, params, fun) do
    with_api_scope(conn, fn scope ->
      case resolve_paste_scope(scope, params) do
        {:ok, paste_scope} -> fun.(paste_scope)
        {:error, :not_found} -> render_workspace_not_found(conn)
      end
    end)
  end

  defp resolve_paste_scope(scope, %{"workspace_id" => workspace_id}) do
    Organizations.resolve_workspace_scope(scope, workspace_id)
  end

  defp resolve_paste_scope(%Scope{user: user} = scope, _params) do
    workspace = Organizations.get_personal_default_workspace!(user)
    Organizations.resolve_workspace_scope(scope, workspace)
  end

  defp paste_location(
         %{path_params: %{"workspace_id" => _workspace_id}},
         %Scope{workspace: workspace},
         %Paste{id: paste_id}
       ) do
    ~p"/api/v1/workspaces/#{workspace.id}/pastes/#{paste_id}"
  end

  defp paste_location(_conn, _scope, %Paste{id: paste_id}),
    do: ~p"/api/v1/pastes/#{paste_id}"

  defp render_workspace_not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{errors: %{detail: "Workspace not found"}})
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
