defmodule TextbinWeb.ApiV1.PasteController do
  use TextbinWeb, :controller

  alias Textbin.Accounts.Scope
  alias Textbin.Pastes

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
      {:ok, paste_attrs, conn} ->
        create_paste(conn, paste_attrs)

      {:error, :too_large, conn} ->
        render_too_large(conn)

      {:error, reason, conn} ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: %{detail: "Could not read request body: #{inspect(reason)}"}})
    end
  end

  # Preferred JSON shape for API clients that already send objects.
  defp paste_attrs(conn, %{"data" => data} = params) when is_binary(data) do
    {:ok, build_paste_attrs(data, params), conn}
  end

  # Keep Phoenix generator-style wrapped params working for conventional clients
  # and tests.
  defp paste_attrs(conn, %{"paste" => %{"data" => data} = params}) when is_binary(data) do
    {:ok, build_paste_attrs(data, params), conn}
  end

  # Plug puts non-object JSON bodies, such as `"hello"`, under "_json". This is
  # useful for callers that want JSON content negotiation without an object
  # envelope.
  defp paste_attrs(conn, %{"_json" => data} = params) when is_binary(data) do
    {:ok, build_paste_attrs(data, params), conn}
  end

  # Non-JSON uploads keep the body unread after Plug.Parsers, so streamed
  # CLI/stdin data can be consumed here.
  defp paste_attrs(conn, params)
       when map_size(params) == 0 or is_map_key(params, "syntax_highlight") or
              is_map_key(params, "expires_in") or is_map_key(params, "ttl") do
    case read_request_body(conn) do
      {:ok, data, conn} ->
        {:ok, build_paste_attrs(data, params), conn}

      {:error, reason, conn} ->
        {:error, reason, conn}
    end
  end

  # Let the changeset produce the canonical "data can't be blank" error for
  # unsupported payload shapes instead of inventing a separate controller error.
  defp paste_attrs(conn, _params) do
    {:ok, %{"data" => nil}, conn}
  end

  defp build_paste_attrs(data, params) do
    %{"data" => data}
    |> put_string_param(params, "syntax_highlight")
    |> put_string_param(params, "expires_in")
    |> put_string_param(params, "ttl")
  end

  defp put_string_param(attrs, params, key) do
    case params do
      %{^key => value} when is_binary(value) -> Map.put(attrs, key, value)
      _params -> attrs
    end
  end

  defp create_paste(conn, paste_params) do
    with_api_scope(conn, &create_scoped_paste(conn, &1, paste_params))
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

  # The current MVP stores data in a single text column, so we still assemble
  # chunks before inserting. The chunked read path keeps the HTTP interface
  # friendly to stdin/pipe callers and leaves room for a streamed storage backend.
  defp read_request_body(conn) do
    read_request_body(conn, [], 0, max_paste_bytes())
  end

  defp read_request_body(conn, chunks, total_size, max_size) do
    case Plug.Conn.read_body(conn, length: @read_chunk_size, read_length: @read_chunk_size) do
      {:ok, chunk, conn} ->
        chunk_size = byte_size(chunk)

        if total_size + chunk_size > max_size do
          {:error, :too_large, conn}
        else
          {:ok, IO.iodata_to_binary(Enum.reverse([chunk | chunks])), conn}
        end

      {:more, chunk, conn} ->
        chunk_size = byte_size(chunk)
        total_size = total_size + chunk_size

        if total_size > max_size do
          {:error, :too_large, conn}
        else
          read_request_body(conn, [chunk | chunks], total_size, max_size)
        end

      {:error, reason} ->
        {:error, reason, conn}
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
      with {:ok, paste_id} <- Ecto.UUID.cast(id),
           %{} = paste <- Pastes.get_paste(current_scope, paste_id) do
        {:ok, _paste} = Pastes.delete_paste(current_scope, paste)
      end

      send_resp(conn, :no_content, "")
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

  defp render_too_large(conn) do
    conn
    |> put_status(413)
    |> json(%{
      errors: %{
        detail: "Paste data exceeds the maximum size of #{max_paste_bytes()} bytes"
      }
    })
  end

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
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: TextbinWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  defp max_paste_bytes do
    Application.get_env(:textbin, :max_paste_bytes, @default_max_paste_bytes)
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
