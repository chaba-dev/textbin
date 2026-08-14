defmodule TextbinWeb.PageControllerTest do
  use TextbinWeb.ConnCase, async: true

  import Textbin.AccountsFixtures

  test "GET / redirects unauthenticated visitors to login", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "GET / redirects authenticated users to pastes", %{conn: conn} do
    conn =
      conn
      |> log_in_user(user_fixture())
      |> get(~p"/")

    assert redirected_to(conn) == ~p"/pastes"
  end
end
