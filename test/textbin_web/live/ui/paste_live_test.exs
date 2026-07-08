defmodule TextbinWeb.UI.PasteLiveTest do
  use TextbinWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Textbin.Pastes

  test "lists pastes", %{conn: conn} do
    {:ok, paste} = Pastes.create_paste(%{data: "live paste data"})

    {:ok, view, _html} = live(conn, ~p"/pastes")

    assert has_element?(view, "#pastes-list")
    assert has_element?(view, "##{stream_id(paste)}", "live paste data")
    assert has_element?(view, "##{stream_id(paste)}", paste.id)
  end

  test "renders an empty state", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/pastes")

    assert has_element?(view, "#pastes-list")
    assert has_element?(view, "#pastes-list", "No pastes yet.")
  end

  defp stream_id(paste), do: "pastes-#{paste.id}"
end
