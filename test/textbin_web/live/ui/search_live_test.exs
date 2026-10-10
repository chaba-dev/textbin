defmodule TextbinWeb.UI.SearchLiveTest do
  use TextbinWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Textbin.AccountsFixtures

  alias Textbin.Organizations
  alias Textbin.Pastes

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user, scope: user_scope_fixture(user)}
  end

  test "requires an account" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/search")
  end

  test "searching updates the URL and shows excerpts with the match marked", context do
    {:ok, paste} =
      Pastes.create_paste(context.scope, %{
        data: "deploy log\nrollback triggered by failing health check on api-7"
      })

    {:ok, view, _html} = live(context.conn, ~p"/search")

    assert has_element?(view, "#search-form input#search_q")
    assert has_element?(view, "#sidebar-navigation-search[aria-current='page']")
    assert has_element?(view, "#mobile-search-link[aria-current='page']")

    view |> form("#search-form", %{"search" => %{"q" => "health check"}}) |> render_change()

    assert_patch(view, ~p"/search?#{[q: "health check"]}")
    assert has_element?(view, "#search-summary", "1 match")
    assert has_element?(view, "#search-result-#{paste.id}", "deploy log")
    assert has_element?(view, "#search-excerpt-#{paste.id} mark", "health check")

    workspace = personal_workspace_fixture(context.user)
    organization = Organizations.get_personal_organization!(context.user)

    assert has_element?(
             view,
             "#search-result-#{paste.id}[href='/w/#{organization.slug}/#{workspace.slug}/pastes/#{paste.id}']"
           )
  end

  test "a query in the URL runs on load and an empty result explains itself", context do
    {:ok, view, _html} = live(context.conn, ~p"/search?#{[q: "nothing like this"]}")

    assert has_element?(view, "#search_q[value='nothing like this']")
    assert has_element?(view, "#search-results-empty", "No pastes match")
  end

  test "results never include other people's workspaces", context do
    {:ok, _paste} = Pastes.create_paste(user_scope_fixture(), %{data: "secret token rotation"})

    {:ok, view, _html} = live(context.conn, ~p"/search?#{[q: "token rotation"]}")

    assert has_element?(view, "#search-summary", "0 matches")
  end
end
