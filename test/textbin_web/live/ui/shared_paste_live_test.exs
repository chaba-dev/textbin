defmodule TextbinWeb.UI.SharedPasteLiveTest do
  use TextbinWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Textbin.AccountsFixtures

  alias Textbin.Pastes

  setup do
    user = user_fixture()
    %{scope: user_scope_fixture(user), user: user}
  end

  test "anonymous viewers can open unlisted and public pastes", %{scope: scope} do
    for visibility <- ["unlisted", "public"] do
      {:ok, paste} =
        Pastes.create_paste(scope, %{
          data: "#{visibility} paste",
          syntax_highlight: "elixir",
          visibility: visibility
        })

      {:ok, view, _html} = live(build_conn(), ~p"/p/#{paste.id}")

      assert has_element?(view, "#shared-paste")
      assert has_element?(view, "#shared-paste-visibility", String.capitalize(visibility))
      assert has_element?(view, "#shared-paste-syntax", "elixir")
      assert has_element?(view, "#shared-paste-data", "#{visibility} paste")
      assert has_element?(view, "#copy-paste-content[phx-hook='CopyToClipboard']")
      assert has_element?(view, "#raw-paste-link[href='/p/#{paste.id}/raw']")
      refute has_element?(view, "#manage-paste-link")
    end
  end

  test "an owner can open and manage a private paste", %{scope: scope, user: user} do
    {:ok, paste} = Pastes.create_paste(scope, %{data: "private paste", visibility: "private"})

    {:ok, view, _html} = live(log_in_user(build_conn(), user), ~p"/p/#{paste.id}")

    assert has_element?(view, "#shared-paste-visibility", "Private")
    assert has_element?(view, "#shared-paste-data", "private paste")
    assert has_element?(view, "#manage-paste-link[href='/pastes/#{paste.id}']")
  end

  test "private pastes are hidden from anonymous and other signed-in viewers", %{scope: scope} do
    {:ok, paste} = Pastes.create_paste(scope, %{data: "private paste", visibility: "private"})

    assert_raise Ecto.NoResultsError, fn ->
      live(build_conn(), ~p"/p/#{paste.id}")
    end

    other_user = user_fixture()

    assert_raise Ecto.NoResultsError, fn ->
      live(log_in_user(build_conn(), other_user), ~p"/p/#{paste.id}")
    end
  end

  test "paste content is escaped before rendering highlighted HTML", %{scope: scope} do
    {:ok, paste} =
      Pastes.create_paste(scope, %{
        data: "<script>alert('nope')</script>",
        syntax_highlight: "plain",
        visibility: "public"
      })

    {:ok, view, _html} = live(build_conn(), ~p"/p/#{paste.id}")

    assert has_element?(view, "#shared-paste-data", "<script>alert('nope')</script>")
    refute has_element?(view, "#shared-paste-data script")
  end
end
