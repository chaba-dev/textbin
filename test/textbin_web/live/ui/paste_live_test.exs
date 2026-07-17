defmodule TextbinWeb.UI.PasteLiveTest do
  use TextbinWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Textbin.AccountsFixtures

  alias Textbin.Pastes

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), scope: user_scope_fixture(user)}
  end

  test "redirects unauthenticated users to login" do
    assert {:error, {:redirect, %{to: path, flash: flash}}} = live(build_conn(), ~p"/pastes")
    assert path == ~p"/users/log-in"
    assert %{"error" => "You must log in to access this page."} = flash
  end

  test "lists scoped pastes", %{conn: conn, scope: scope} do
    {:ok, paste} =
      Pastes.create_paste(scope, %{data: "live paste data", syntax_highlight: "elixir"})

    {:ok, other_paste} =
      Pastes.create_paste(user_scope_fixture(), %{data: "other user data"})

    {:ok, view, _html} = live(conn, ~p"/pastes")

    assert has_element?(view, "#pastes-list")
    assert has_element?(view, "##{stream_id(paste)}", paste.id)
    assert has_element?(view, "##{stream_id(paste)}", "elixir")
    assert has_element?(view, "#paste-expires-at-#{paste.id}", "Never expires")
    assert has_element?(view, "##{stream_id(paste)} a[href='/pastes/#{paste.id}']")
    refute has_element?(view, "##{stream_id(paste)}", "live paste data")
    refute has_element?(view, "##{stream_id(other_paste)}")
  end

  test "renders an empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pastes")

    assert has_element?(view, "#pastes-list")
    assert has_element?(view, "#pastes-empty.min-h-56.text-base", "No pastes yet.")
  end

  test "creates a paste from the UI", %{conn: conn, scope: scope} do
    {:ok, view, _html} = live(conn, ~p"/pastes")

    assert has_element?(view, "#paste-form")

    view
    |> form("#paste-form", %{
      "paste" => %{
        "data" => "created from the browser",
        "syntax_highlight" => "markdown",
        "expires_in" => "never"
      }
    })
    |> render_submit()

    assert [paste] = Pastes.list_pastes(scope)
    assert paste.data == "created from the browser"
    assert paste.syntax_highlight == "markdown"
    assert is_nil(paste.expires_at)
    assert has_element?(view, "##{stream_id(paste)}", "markdown")
  end

  test "creates a paste with the user's default expiration", %{scope: scope} do
    {:ok, user} =
      Textbin.Accounts.update_user_paste_defaults(scope.user, %{default_paste_ttl: "1h"})

    scope = %{scope | user: user}
    conn = log_in_user(build_conn(), user)

    {:ok, view, _html} = live(conn, ~p"/pastes")

    view
    |> form("#paste-form", %{
      "paste" => %{
        "data" => "uses account default",
        "syntax_highlight" => "plain",
        "expires_in" => ""
      }
    })
    |> render_submit()

    assert [paste] = Pastes.list_pastes(scope)
    assert DateTime.diff(paste.expires_at, DateTime.utc_now(), :second) in 3590..3600
    assert has_element?(view, "#paste-expires-at-#{paste.id}", "Expires")
  end

  test "shows an individual paste", %{conn: conn, scope: scope} do
    {:ok, paste} =
      Pastes.create_paste(scope, %{data: "individual paste data", syntax_highlight: "json"})

    {:ok, view, _html} = live(conn, ~p"/pastes/#{paste.id}")

    assert has_element?(view, "h1", paste.id)
    assert has_element?(view, "span", "json")
    assert has_element?(view, "#paste-expires-at", "Never expires")
    assert has_element?(view, "#paste-data .lumis code.language-json")
    assert has_element?(view, "#paste-data .l-line[data-line='1']")
    assert has_element?(view, "#paste-data", "individual paste data")
    assert has_element?(view, "a[href='/pastes']", "Back to pastes")
  end

  test "escapes paste data before rendering highlighted HTML", %{conn: conn, scope: scope} do
    {:ok, paste} =
      Pastes.create_paste(scope, %{
        data: "<script>alert('nope')</script>",
        syntax_highlight: "plain"
      })

    {:ok, view, _html} = live(conn, ~p"/pastes/#{paste.id}")

    assert has_element?(view, "#paste-data .lumis code.language-plaintext")
    assert has_element?(view, "#paste-data", "<script>alert('nope')</script>")
    refute has_element?(view, "#paste-data script")
  end

  test "deletes a paste from the list", %{conn: conn, scope: scope} do
    {:ok, paste} = Pastes.create_paste(scope, %{data: "delete from list"})

    {:ok, view, _html} = live(conn, ~p"/pastes")

    assert has_element?(
             view,
             "#delete-paste-#{paste.id}[data-confirm='Delete this paste?']"
           )

    view
    |> element("#delete-paste-#{paste.id}")
    |> render_click()

    refute has_element?(view, "##{stream_id(paste)}")
    assert_raise Ecto.NoResultsError, fn -> Pastes.get_paste!(scope, paste.id) end
  end

  test "deletes a paste from the detail page", %{conn: conn, scope: scope} do
    {:ok, paste} = Pastes.create_paste(scope, %{data: "delete from detail"})

    {:ok, view, _html} = live(conn, ~p"/pastes/#{paste.id}")

    assert has_element?(
             view,
             "#delete-paste-#{paste.id}[data-confirm='Delete this paste?']"
           )

    view
    |> element("#delete-paste-#{paste.id}")
    |> render_click()

    assert_redirect(view, ~p"/pastes")
    assert_raise Ecto.NoResultsError, fn -> Pastes.get_paste!(scope, paste.id) end
  end

  defp stream_id(paste), do: "pastes-#{paste.id}"
end
