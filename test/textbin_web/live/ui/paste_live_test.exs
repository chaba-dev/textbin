defmodule TextbinWeb.UI.PasteLiveTest do
  use TextbinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Textbin.AccountsFixtures

  alias Textbin.Pastes.Paste
  alias Textbin.Pastes
  alias Textbin.Repo

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), scope: user_scope_fixture(user)}
  end

  test "redirects unauthenticated users to login" do
    assert {:error, {:redirect, %{to: path, flash: flash}}} = live(build_conn(), ~p"/pastes")
    assert path == ~p"/users/log-in"
    assert %{"error" => "You must log in to access this page."} = flash
  end

  test "allows guest paste creation when enabled" do
    put_guest_pastes_enabled(true)

    {:ok, view, _html} = live(build_conn(), ~p"/pastes")

    assert has_element?(view, "#paste-form")
    assert has_element?(view, "#paste_visibility[disabled] option[value='unlisted']")

    view
    |> form("#paste-form", %{
      "paste" => %{
        "data" => "guest paste",
        "syntax_highlight" => "plain",
        "expires_in" => ""
      }
    })
    |> render_submit()

    paste =
      Paste
      |> Repo.one!()
      |> Repo.preload(:user)

    assert paste.data == "guest paste"
    assert paste.user.kind == "guest"
    assert paste.visibility == "unlisted"
    assert DateTime.diff(paste.expires_at, DateTime.utc_now(), :second) in 21_590..21_600
    assert has_element?(view, "##{stream_id(paste)}", "plain")
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
    assert has_element?(view, "#paste-visibility-#{paste.id}", "Private")
    assert has_element?(view, "#paste-expires-at-#{paste.id}", "Never expires")
    assert has_element?(view, "##{stream_id(paste)} a[href='/pastes/#{paste.id}']")
    assert has_element?(view, "#open-shared-paste-#{paste.id}[href='/p/#{paste.id}']")
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
    assert has_element?(view, "#paste_visibility option[value='private']")
    assert has_element?(view, "#paste_visibility option[value='unlisted']")
    assert has_element?(view, "#paste_visibility option[value='public']")

    view
    |> form("#paste-form", %{
      "paste" => %{
        "data" => "created from the browser",
        "syntax_highlight" => "markdown",
        "visibility" => "public",
        "expires_in" => "never"
      }
    })
    |> render_submit()

    assert [paste] = Pastes.list_pastes(scope)
    assert paste.data == "created from the browser"
    assert paste.syntax_highlight == "markdown"
    assert paste.visibility == "public"
    assert is_nil(paste.expires_at)
    assert has_element?(view, "##{stream_id(paste)}", "markdown")
    assert has_element?(view, "#paste-visibility-#{paste.id}", "Public")
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
    assert has_element?(view, "#paste-visibility", "Private")
    assert has_element?(view, "#paste-expires-at", "Never expires")
    assert has_element?(view, "#paste-data .lumis code.language-json")
    assert has_element?(view, "#paste-data .l-line[data-line='1']")
    assert has_element?(view, "#paste-data", "individual paste data")
    assert has_element?(view, "a[href='/pastes']", "Back to pastes")
    assert has_element?(view, "a[href='/p/#{paste.id}']", "Open viewer")
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

  defp put_guest_pastes_enabled(enabled?) do
    previous = Application.get_env(:textbin, :allow_guest_pastes)
    Application.put_env(:textbin, :allow_guest_pastes, enabled?)

    on_exit(fn ->
      Application.put_env(:textbin, :allow_guest_pastes, previous)
    end)
  end
end
