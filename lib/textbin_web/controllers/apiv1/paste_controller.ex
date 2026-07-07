defmodule TextbinWeb.ApiV1.PasteController do
  use TextbinWeb, :controller

  alias Textbin.Pastes

  # Keep raw upload reads small enough that an oversized request is rejected
  # after one bounded chunk instead of being accumulated in memory.
  @read_chunk_size 64_000

  # 1 MiB is the MVP safety limit when config does not provide
  # :max_paste_bytes.
  @default_max_paste_bytes 1_048_576

  def index(conn, _params) do
    pastes = Pastes.list_pastes()
    render(conn, :index, pastes: pastes)
  end

  # Treat create as "store the request body as paste data" while still accepting
  # common JSON client shapes. This keeps CLI usage simple without making API
  # clients wrap data unless they want to.
  def create(conn, params) do
    case paste_data(conn, params) do
      {:ok, data, conn} ->
        create_paste(conn, %{"data" => data})

      {:error, :too_large, conn} ->
        render_too_large(conn)

      {:error, reason, conn} ->
        conn
        |> put_status(:bad_request)
        |> json(%{errors: %{detail: "Could not read request body: #{inspect(reason)}"}})
    end
  end

  # Preferred JSON shape for API clients that already send objects.
  defp paste_data(conn, %{"data" => data}) when is_binary(data) do
    {:ok, data, conn}
  end

  # Keep Phoenix generator-style wrapped params working for conventional clients
  # and tests.
  defp paste_data(conn, %{"paste" => %{"data" => data}}) when is_binary(data) do
    {:ok, data, conn}
  end

  # Plug puts non-object JSON bodies, such as `"hello"`, under "_json". This is
  # useful for callers that want JSON content negotiation without an object
  # envelope.
  defp paste_data(conn, %{"_json" => data}) when is_binary(data) do
    {:ok, data, conn}
  end

  # Non-JSON uploads keep the body unread after Plug.Parsers, so streamed
  # CLI/stdin data can be consumed here.
  defp paste_data(conn, params) when params == %{} do
    read_request_body(conn)
  end

  # Let the changeset produce the canonical "data can't be blank" error for
  # unsupported payload shapes instead of inventing a separate controller error.
  defp paste_data(conn, _params) do
    {:ok, nil, conn}
  end

  defp create_paste(conn, paste_params) do
    case validate_paste_size(paste_params) do
      :ok ->
        case Pastes.create_paste(paste_params) do
          {:ok, paste} ->
            conn
            |> put_status(:created)
            |> put_resp_header("location", ~p"/api/v1/pastes/#{paste.id}")
            |> render(:show, paste: paste)

          {:error, changeset} ->
            render_changeset_errors(conn, changeset)
        end

      {:error, :too_large} ->
        render_too_large(conn)
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
    paste = Pastes.get_paste!(id)
    render(conn, :show, paste: paste)
  end

  def update(conn, %{"id" => id} = params) do
    paste = Pastes.get_paste!(id)
    paste_params = paste_params(params)

    case validate_paste_size(paste_params) do
      :ok ->
        case Pastes.update_paste(paste, paste_params) do
          {:ok, paste} ->
            render(conn, :show, paste: paste)

          {:error, changeset} ->
            render_changeset_errors(conn, changeset)
        end

      {:error, :too_large} ->
        render_too_large(conn)
    end
  end

  defp paste_params(%{"data" => data}) when is_binary(data), do: %{"data" => data}
  defp paste_params(%{"paste" => %{"data" => data}}) when is_binary(data), do: %{"data" => data}
  defp paste_params(_params), do: %{"data" => nil}

  def delete(conn, %{"id" => id}) do
    paste = Pastes.get_paste!(id)
    {:ok, _paste} = Pastes.delete_paste(paste)

    send_resp(conn, :no_content, "")
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

  defp render_changeset_errors(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: TextbinWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  defp max_paste_bytes do
    Application.get_env(:textbin, :max_paste_bytes, @default_max_paste_bytes)
  end
end
