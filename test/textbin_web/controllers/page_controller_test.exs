defmodule TextbinWeb.PageControllerTest do
  use TextbinWeb.ConnCase, async: true

  import Textbin.AccountsFixtures

  alias Textbin.Accounts
  alias Textbin.Accounts.Scope
  alias Textbin.Organizations

  test "GET / redirects unauthenticated visitors to login", %{conn: conn} do
    conn = get(conn, ~p"/")

    assert redirected_to(conn) == ~p"/users/log-in"
  end

  test "GET / opens the personal workspace before any other is used", %{conn: conn} do
    user = user_fixture()
    workspace = personal_workspace_fixture(user)
    organization = Organizations.get_personal_organization!(user)

    conn = conn |> log_in_user(user) |> get(~p"/")

    assert redirected_to(conn) == "/w/#{organization.slug}/#{workspace.slug}/pastes"
  end

  test "GET / reopens the last workspace the user worked in", %{conn: conn} do
    user = user_fixture()

    {:ok, organization} =
      Organizations.create_organization(Scope.for_user(user), %{name: "Ops", slug: "ops-home"})

    [workspace] = organization.workspaces
    :ok = Accounts.remember_last_workspace(user, workspace.id)

    conn = conn |> log_in_user(user) |> get(~p"/")

    assert redirected_to(conn) == "/w/ops-home/#{workspace.slug}/pastes"
  end
end
