defmodule TextbinWeb.PasteController do
  use TextbinWeb, :controller

  alias Textbin.Pastes

  def index(conn, _params) do
    pastes = Pastes.list_pastes()
    render(conn, :index, pastes: pastes)
  end

  def create(conn, %{"paste" => paste_params}) do
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

  def show(conn, %{"id" => id}) do
    paste = Pastes.get_paste!(id)
    render(conn, :show, paste: paste)
  end

  def update(conn, %{"id" => id, "paste" => paste_params}) do
    paste = Pastes.get_paste!(id)

    case Pastes.update_paste(paste, paste_params) do
      {:ok, paste} ->
        render(conn, :show, paste: paste)

      {:error, changeset} ->
        render_changeset_errors(conn, changeset)
    end
  end

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
