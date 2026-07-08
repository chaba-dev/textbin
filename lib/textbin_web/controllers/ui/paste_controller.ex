defmodule TextbinWeb.UI.PasteController do
  use TextbinWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
