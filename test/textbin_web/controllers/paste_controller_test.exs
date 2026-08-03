defmodule TextbinWeb.PasteControllerTest do
  use TextbinWeb.ConnCase, async: true

  alias Textbin.Pastes
  alias Textbin.Pastes.Paste
  alias Textbin.Repo

  import Textbin.AccountsFixtures

  setup do
    user = user_fixture()
    %{scope: user_scope_fixture(user), user: user}
  end

  test "raw returns unlisted and public paste content to anonymous viewers", %{scope: scope} do
    for visibility <- ["unlisted", "public"] do
      content = "#{visibility}\ncontent\n"
      {:ok, paste} = Pastes.create_paste(scope, %{data: content, visibility: visibility})

      conn = get(build_conn(), ~p"/pastes/#{paste.id}/raw")

      assert response(conn, 200) == content
      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]
    end
  end

  test "raw returns a private paste to its signed-in owner", %{scope: scope, user: user} do
    {:ok, paste} = Pastes.create_paste(scope, %{data: "private raw", visibility: "private"})

    conn =
      build_conn()
      |> log_in_user(user)
      |> get(~p"/pastes/#{paste.id}/raw")

    assert response(conn, 200) == "private raw"
  end

  test "raw hides private pastes from anonymous and other signed-in viewers", %{scope: scope} do
    {:ok, paste} = Pastes.create_paste(scope, %{data: "private raw", visibility: "private"})

    assert response(get(build_conn(), ~p"/pastes/#{paste.id}/raw"), 404) == "Not Found"

    other_user = user_fixture()

    other_conn =
      build_conn()
      |> log_in_user(other_user)
      |> get(~p"/pastes/#{paste.id}/raw")

    assert response(other_conn, 404) == "Not Found"
  end

  test "raw hides expired pastes", %{scope: scope} do
    paste =
      Repo.insert!(%Paste{
        data: "expired raw",
        syntax_highlight: "plain",
        visibility: "public",
        user_id: scope.user.id,
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
      })

    assert response(get(build_conn(), ~p"/pastes/#{paste.id}/raw"), 404) == "Not Found"
  end

  test "raw returns not found for an invalid paste id" do
    assert response(get(build_conn(), ~p"/pastes/not-a-uuid/raw"), 404) == "Not Found"
  end
end
