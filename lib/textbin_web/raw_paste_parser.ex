defmodule TextbinWeb.RawPasteParser do
  @moduledoc """
  Leaves non-JSON API paste uploads unread for the bounded upload spooler.
  Runs before the standard parsers so form, multipart and +json media types
  remain exact paste bytes rather than becoming controller parameters.
  Browser forms and exact application/json API bodies use the usual parsers.
  """

  @behaviour Plug.Parsers

  @impl true
  def init(opts), do: opts

  @impl true
  def parse(conn, "application", "json", _headers, _opts), do: {:next, conn}

  def parse(
        %{method: "POST", path_info: ["api", "v1", "pastes"]} = conn,
        _type,
        _subtype,
        _headers,
        _opts
      ),
      do: raw(conn)

  def parse(
        %{method: "POST", path_info: ["api", "v1", "workspaces", _id, "pastes"]} = conn,
        _type,
        _subtype,
        _headers,
        _opts
      ),
      do: raw(conn)

  def parse(conn, _type, _subtype, _headers, _opts), do: {:next, conn}

  defp raw(conn), do: {:ok, %{}, Plug.Conn.put_private(conn, :raw_paste_upload, true)}
end
