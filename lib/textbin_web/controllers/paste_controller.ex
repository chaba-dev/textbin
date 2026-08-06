defmodule TextbinWeb.PasteController do
  use TextbinWeb, :controller

  alias Textbin.Pastes
  alias Textbin.Pastes.ContentType
  alias Textbin.Pastes.Paste

  def raw(conn, %{"id" => id}) do
    case Pastes.get_shared_paste(conn.assigns.current_scope, id) do
      %Paste{} = paste ->
        conn
        |> put_resp_header("x-content-type-options", "nosniff")
        |> maybe_force_download(paste)
        |> put_paste_content_type(paste)
        |> send_resp(:ok, paste.data)

      nil ->
        send_resp(conn, :not_found, "Not Found")
    end
  end

  defp put_paste_content_type(conn, %Paste{} = paste) do
    if text_response?(paste) do
      put_resp_content_type(conn, paste.content_type, "utf-8")
    else
      put_resp_content_type(conn, ContentType.binary(), nil)
    end
  end

  defp maybe_force_download(conn, %Paste{} = paste) do
    if ContentType.active?(paste.content_type) or !text_response?(paste) do
      put_resp_header(conn, "content-disposition", ~s(attachment; filename="paste-#{paste.id}"))
    else
      conn
    end
  end

  defp text_response?(paste) do
    ContentType.textual?(paste.content_type) and ContentType.text_safe?(paste.data)
  end
end
