defmodule TextbinWeb.PasteControllerTest do
  use TextbinWeb.ConnCase, async: true

  alias Textbin.Pastes

  @create_attrs %{content: "some content"}
  @update_attrs %{content: "updated content"}
  @invalid_attrs %{content: nil}

  describe "index" do
    test "lists all pastes", %{conn: conn} do
      {:ok, paste} = Pastes.create_paste(@create_attrs)

      conn = get(conn, ~p"/api/v1/pastes")

      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["id"] == paste.id
    end
  end

  describe "create paste" do
    test "renders paste when data is valid", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/pastes", paste: @create_attrs)

      assert %{"id" => id} = json_response(conn, 201)["data"]

      conn = get(conn, ~p"/api/v1/pastes/#{id}")

      assert %{
               "id" => ^id,
               "content" => "some content",
               "inserted_at" => inserted_at,
               "updated_at" => updated_at
             } = json_response(conn, 200)["data"]

      assert_millisecond_timestamp(inserted_at)
      assert_millisecond_timestamp(updated_at)
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/pastes", paste: @invalid_attrs)

      assert %{"content" => [_]} = json_response(conn, 422)["errors"]
    end
  end

  describe "update paste" do
    test "renders paste when data is valid", %{conn: conn} do
      {:ok, paste} = Pastes.create_paste(@create_attrs)

      conn = patch(conn, ~p"/api/v1/pastes/#{paste.id}", paste: @update_attrs)

      assert %{"id" => id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/api/v1/pastes/#{id}")

      assert %{
               "id" => ^id,
               "content" => "updated content"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      {:ok, paste} = Pastes.create_paste(@create_attrs)

      conn = patch(conn, ~p"/api/v1/pastes/#{paste.id}", paste: @invalid_attrs)

      assert %{"content" => [_]} = json_response(conn, 422)["errors"]
    end
  end

  describe "delete paste" do
    test "deletes chosen paste", %{conn: conn} do
      {:ok, paste} = Pastes.create_paste(@create_attrs)

      conn = delete(conn, ~p"/api/v1/pastes/#{paste.id}")

      assert response(conn, 204)
      assert_raise Ecto.NoResultsError, fn -> Pastes.get_paste!(paste.id) end
    end
  end

  defp assert_millisecond_timestamp(timestamp) do
    assert timestamp =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/
  end
end
