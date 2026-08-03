defmodule TextbinWeb.PasteController do
  use TextbinWeb, :controller

  alias Textbin.Pastes
  alias Textbin.Pastes.Paste

  def raw(conn, %{"id" => id}) do
    case Pastes.get_shared_paste(conn.assigns.current_scope, id) do
      %Paste{} = paste ->
        conn
        |> put_resp_content_type("text/plain", "utf-8")
        |> send_resp(:ok, paste.data)

      nil ->
        send_resp(conn, :not_found, "Not Found")
    end
  end
end
