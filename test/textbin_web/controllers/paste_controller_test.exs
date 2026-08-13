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

  test "raw preserves HTML content type but forces a safe download", %{scope: scope} do
    {:ok, paste} =
      Pastes.create_paste(scope, %{
        data: "<script>alert('unsafe')</script>",
        content_type: "text/html",
        visibility: "public"
      })

    conn = get(build_conn(), ~p"/pastes/#{paste.id}/raw")

    assert response(conn, 200) == "<script>alert('unsafe')</script>"
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]

    assert get_resp_header(conn, "content-disposition") == [
             ~s(attachment; filename="paste-#{paste.id}")
           ]

    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
  end

  test "raw forces executable XML to download with a sandbox policy", %{scope: scope} do
    data = ~S|<script xmlns="http://www.w3.org/1999/xhtml">alert("unsafe")</script>|

    {:ok, paste} =
      Pastes.create_paste(scope, %{
        data: data,
        content_type: "application/xml",
        visibility: "public"
      })

    conn = get(build_conn(), ~p"/pastes/#{paste.id}/raw")

    assert response(conn, 200) == data
    assert get_resp_header(conn, "content-disposition") != []
    assert get_resp_header(conn, "content-security-policy") == ["sandbox; default-src 'none'"]
  end

  test "raw serves binary bytes as an attachment", %{scope: scope} do
    data = <<255, 0, 1>>
    {:ok, paste} = Pastes.create_paste(scope, %{data: data, visibility: "public"})

    conn = get(build_conn(), ~p"/pastes/#{paste.id}/raw")

    assert response(conn, 200) == data
    assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
    assert get_resp_header(conn, "content-disposition") != []
  end

  test "raw safely serves legacy binary content backfilled as text/plain", %{scope: scope} do
    data = <<255, 0, 1>>
    {:ok, paste} = Pastes.create_paste(scope, %{data: data, visibility: "public"})

    paste
    |> Repo.reload!()
    |> Ecto.Changeset.change(content_type: "text/plain")
    |> Repo.update!()

    conn = get(build_conn(), ~p"/pastes/#{paste.id}/raw")

    assert response(conn, 200) == data
    assert get_resp_header(conn, "content-type") == ["application/octet-stream"]
    assert get_resp_header(conn, "content-disposition") != []
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
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
    workspace = personal_workspace_fixture(scope.user)

    paste =
      Repo.insert!(%Paste{
        data: "expired raw",
        syntax_highlight: "plain",
        audience: "public",
        workspace_id: workspace.id,
        created_by_user_id: scope.user.id,
        expires_at: DateTime.add(DateTime.utc_now(), -1, :second)
      })

    assert response(get(build_conn(), ~p"/pastes/#{paste.id}/raw"), 404) == "Not Found"
  end

  test "raw returns not found for an invalid paste id" do
    assert response(get(build_conn(), ~p"/pastes/not-a-uuid/raw"), 404) == "Not Found"
  end
end
