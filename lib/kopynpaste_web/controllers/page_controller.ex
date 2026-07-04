defmodule KopynpasteWeb.PageController do
  use KopynpasteWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
