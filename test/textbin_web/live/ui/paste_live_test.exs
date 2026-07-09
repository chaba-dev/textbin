defmodule TextbinWeb.UI.PasteLiveTest do
  use TextbinWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Textbin.Pastes

  test "lists pastes", %{conn: conn} do
    {:ok, paste} = Pastes.create_paste(%{data: "live paste data"})

    {:ok, view, _html} = live(conn, ~p"/pastes")

    assert has_element?(view, "#pastes-list")
    assert has_element?(view, "##{stream_id(paste)}", paste.id)
    assert has_element?(view, "##{stream_id(paste)} a[href='/pastes/#{paste.id}']")
    refute has_element?(view, "##{stream_id(paste)}", "live paste data")
  end

  test "renders an empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pastes")

    assert has_element?(view, "#pastes-list")
    assert has_element?(view, "#pastes-list", "No pastes yet.")
  end

  test "shows an individual paste", %{conn: conn} do
    {:ok, paste} = Pastes.create_paste(%{data: "individual paste data"})

    {:ok, view, _html} = live(conn, ~p"/pastes/#{paste.id}")

    assert has_element?(view, "h1", paste.id)
    assert has_element?(view, "#paste-data", "individual paste data")
    assert has_element?(view, "a[href='/pastes']", "Back to pastes")
  end

  test "deletes a paste from the list", %{conn: conn} do
    {:ok, paste} = Pastes.create_paste(%{data: "delete from list"})

    {:ok, view, _html} = live(conn, ~p"/pastes")

    assert has_element?(
             view,
             "#delete-paste-#{paste.id}[data-confirm='Delete this paste?']"
           )

    view
    |> element("#delete-paste-#{paste.id}")
    |> render_click()

    refute has_element?(view, "##{stream_id(paste)}")
    assert_raise Ecto.NoResultsError, fn -> Pastes.get_paste!(paste.id) end
  end

  test "deletes a paste from the detail page", %{conn: conn} do
    {:ok, paste} = Pastes.create_paste(%{data: "delete from detail"})

    {:ok, view, _html} = live(conn, ~p"/pastes/#{paste.id}")

    assert has_element?(
             view,
             "#delete-paste-#{paste.id}[data-confirm='Delete this paste?']"
           )

    view
    |> element("#delete-paste-#{paste.id}")
    |> render_click()

    assert_redirect(view, ~p"/pastes")
    assert_raise Ecto.NoResultsError, fn -> Pastes.get_paste!(paste.id) end
  end

  defp stream_id(paste), do: "pastes-#{paste.id}"
end
