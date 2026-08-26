defmodule TextbinWeb.UI.AdminLiveTest do
  use TextbinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Textbin.AccountsFixtures

  alias Textbin.Accounts.Scope
  alias Textbin.Administration
  alias Textbin.Pastes
  alias Textbin.Repo
  alias TextbinWeb.ForbiddenError

  setup %{conn: conn} do
    admin = user_fixture()
    assert {:ok, :granted} = Administration.bootstrap_platform_admin(admin.email)
    admin = Repo.get!(Textbin.Accounts.User, admin.id)

    %{admin: admin, conn: log_in_user(conn, admin)}
  end

  test "requires authentication and current platform authority", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/admin")

    ordinary_user = user_fixture()

    assert_raise ForbiddenError, fn ->
      ordinary_user
      |> then(&log_in_user(build_conn(), &1))
      |> live(~p"/admin")
    end

    assert {:ok, view, _html} = live(conn, ~p"/admin")
    assert has_element?(view, "#platform-admin-page")
  end

  test "renders bounded operational metadata without paste bodies", %{conn: conn} do
    owner = user_fixture()

    assert {:ok, paste} =
             Pastes.create_paste(Scope.for_user(owner), %{
               data: "highly-sensitive-body-marker",
               audience: "public"
             })

    assert {:ok, view, html} = live(conn, ~p"/admin")

    assert has_element?(view, "#installation-overview")
    assert has_element?(view, "#admin-lookup-form")
    assert has_element?(view, "#recent-public-pastes-entries a[href='/pastes/#{paste.id}']")
    assert has_element?(view, "#largest-pastes")
    assert has_element?(view, "#platform-audit-log")
    refute html =~ "highly-sensitive-body-marker"
  end

  test "looks up exact users and membership summaries", %{conn: conn} do
    target = user_fixture()
    assert {:ok, view, _html} = live(conn, ~p"/admin")

    view
    |> form("#admin-lookup-form", lookup: %{query: target.email})
    |> render_submit()

    assert has_element?(view, "#admin-user-result", target.email)
    refute has_element?(view, "#admin-lookup-empty")

    view
    |> form("#admin-lookup-form", lookup: %{query: "missing@example.com"})
    |> render_submit()

    assert has_element?(view, "#admin-lookup-empty")
  end

  test "renders every protected largest-paste row without exposing capability IDs", %{conn: conn} do
    owner = user_fixture()
    scope = Scope.for_user(owner)

    assert {:ok, first} =
             Pastes.create_paste(scope, %{
               data: String.duplicate("a", 200),
               audience: "unlisted"
             })

    assert {:ok, second} =
             Pastes.create_paste(scope, %{
               data: String.duplicate("b", 100),
               audience: "workspace"
             })

    assert {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "#largest-pastes-entries article + article")
    refute has_element?(view, "#largest-pastes-entries a[href='/pastes/#{first.id}']")
    refute has_element?(view, "#largest-pastes-entries a[href='/pastes/#{second.id}']")

    row_ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#largest-pastes-entries article")
      |> LazyHTML.attribute("id")

    assert length(row_ids) == 2
    assert length(Enum.uniq(row_ids)) == 2
  end

  test "leaves the panel promptly when authority is revoked", %{admin: admin, conn: conn} do
    actor = user_fixture()
    assert {:ok, :granted} = Administration.bootstrap_platform_admin(actor.email)
    actor = Repo.get!(Textbin.Accounts.User, actor.id)
    actor_scope = Scope.for_user(%{actor | authenticated_at: DateTime.utc_now(:second)})

    assert {:ok, view, _html} = live(conn, ~p"/admin")

    assert {:ok, _revoked} =
             Administration.revoke_platform_admin(actor_scope, admin, "operator rotation")

    assert_redirect(view, ~p"/")
  end
end
