defmodule TextbinWeb.PageController do
  use TextbinWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
