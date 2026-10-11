defmodule TextbinWeb.PasteController do
  use TextbinWeb, :controller
  use OpenApiSpex.ControllerSpecs

  import TextbinWeb.ApiDocs

  alias OpenApiSpex.{MediaType, Response, Schema}
  alias Textbin.Pastes
  alias Textbin.Pastes.ContentType
  alias Textbin.Pastes.Paste

  tags ["Pastes"]

  operation :raw,
    operation_id: "getRawPaste",
    summary: "Download a paste's exact stored bytes",
    description:
      "Uses the browser session or the paste's link, not a bearer token. Text that is safe to show inline is served with its content type; anything else downloads.",
    security: [],
    parameters: [
      id: uuid_path("Paste id"),
      download: query(%Schema{type: :string}, "Present to download even safe text")
    ],
    responses: %{
      200 => %Response{
        description: "The stored bytes",
        content: %{"*/*" => %MediaType{schema: %Schema{type: :string, format: :binary}}}
      },
      404 => %Response{
        description: "Not found, or not shared with you",
        content: %{"text/plain" => %MediaType{schema: %Schema{type: :string}}}
      }
    }

  def raw(conn, %{"id" => id} = params) do
    case Pastes.get_shared_paste(conn.assigns.current_scope, id) do
      %Paste{} = paste ->
        conn
        |> put_resp_header("x-content-type-options", "nosniff")
        |> put_resp_header("content-security-policy", "sandbox; default-src 'none'")
        |> maybe_force_download(paste, Map.has_key?(params, "download"))
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

  # Unsafe content always downloads; the detail page's Download action asks for
  # the same treatment explicitly so safe text can be saved as a file too.
  defp maybe_force_download(conn, %Paste{} = paste, requested?) do
    if requested? or !ContentType.inline_safe?(paste.content_type) or !text_response?(paste) do
      put_resp_header(conn, "content-disposition", ~s(attachment; filename="paste-#{paste.id}"))
    else
      conn
    end
  end

  defp text_response?(paste) do
    ContentType.textual?(paste.content_type) and ContentType.text_safe?(paste.data)
  end
end
