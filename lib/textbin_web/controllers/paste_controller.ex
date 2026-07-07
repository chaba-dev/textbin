defmodule TextbinWeb.PasteController do
  use TextbinWeb, :controller

  alias Textbin.Pastes

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
    case Pastes.create_paste(paste_params) do
      {:ok, paste} ->
        conn
        |> put_status(:created)
        |> put_resp_header("location", ~p"/api/v1/pastes/#{paste.id}")
        |> render(:show, paste: paste)

      {:error, changeset} ->
        render_changeset_errors(conn, changeset)
    end
  end

  # The current MVP stores data in a single text column, so we still assemble
  # chunks before inserting. The chunked read path keeps the HTTP interface
  # friendly to stdin/pipe callers and leaves room for a streamed storage backend.
  defp read_request_body(conn, chunks \\ []) do
    case Plug.Conn.read_body(conn, length: 64_000, read_length: 64_000) do
      {:ok, chunk, conn} ->
        {:ok, IO.iodata_to_binary(Enum.reverse([chunk | chunks])), conn}

      {:more, chunk, conn} ->
        read_request_body(conn, [chunk | chunks])

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

    case Pastes.update_paste(paste, paste_params) do
      {:ok, paste} ->
        render(conn, :show, paste: paste)

      {:error, changeset} ->
        render_changeset_errors(conn, changeset)
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

  defp render_changeset_errors(conn, changeset) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: TextbinWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end
end
