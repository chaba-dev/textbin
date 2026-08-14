defmodule TextbinWeb.PageController do
  use TextbinWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/pastes")
  end
end
