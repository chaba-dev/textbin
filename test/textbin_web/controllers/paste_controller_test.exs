defmodule TextbinWeb.PasteControllerTest do
  use TextbinWeb.ConnCase, async: true

  alias Textbin.Pastes

  @max_paste_bytes 1_048_576
  @create_attrs %{data: "some data"}
  @update_attrs %{data: "updated data"}
  @invalid_attrs %{data: nil}

  describe "index" do
    test "lists all pastes", %{conn: conn} do
      {:ok, paste} = Pastes.create_paste(%{data: "some data"})

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
               "data" => "some data",
               "inserted_at" => inserted_at,
               "updated_at" => updated_at
             } = json_response(conn, 200)["data"]

      assert_millisecond_timestamp(inserted_at)
      assert_millisecond_timestamp(updated_at)
    end

    test "renders paste from flat JSON data", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/pastes", @create_attrs)

      assert %{
               "data" => "some data"
             } = json_response(conn, 201)["data"]
    end

    test "renders paste from JSON string body", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/pastes", Jason.encode!("json string data"))

      assert %{
               "data" => "json string data"
             } = json_response(conn, 201)["data"]
    end

    test "renders paste from raw request body", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post(~p"/api/v1/pastes", "streamed data")

      assert %{
               "data" => "streamed data"
             } = json_response(conn, 201)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/pastes", paste: @invalid_attrs)

      assert %{"data" => [_]} = json_response(conn, 422)["errors"]
    end

    test "rejects JSON data over the configured size limit", %{conn: conn} do
      too_large_data = String.duplicate("a", @max_paste_bytes + 1)

      conn = post(conn, ~p"/api/v1/pastes", %{data: too_large_data})

      assert %{
               "errors" => %{
                 "detail" => "Paste data exceeds the maximum size of 1048576 bytes"
               }
             } = json_response(conn, 413)
    end

    test "rejects raw request bodies over the configured size limit", %{conn: conn} do
      too_large_data = String.duplicate("a", @max_paste_bytes + 1)

      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post(~p"/api/v1/pastes", too_large_data)

      assert %{
               "errors" => %{
                 "detail" => "Paste data exceeds the maximum size of 1048576 bytes"
               }
             } = json_response(conn, 413)
    end

    test "uses the configured size limit", %{conn: conn} do
      put_max_paste_bytes(4)

      conn = post(conn, ~p"/api/v1/pastes", %{data: "12345"})

      assert %{
               "errors" => %{
                 "detail" => "Paste data exceeds the maximum size of 4 bytes"
               }
             } = json_response(conn, 413)
    end
  end

  describe "update paste" do
    test "renders paste when data is valid", %{conn: conn} do
      {:ok, paste} = Pastes.create_paste(%{data: "some data"})

      conn = patch(conn, ~p"/api/v1/pastes/#{paste.id}", paste: @update_attrs)

      assert %{"id" => id} = json_response(conn, 200)["data"]

      conn = get(conn, ~p"/api/v1/pastes/#{id}")

      assert %{
               "id" => ^id,
               "data" => "updated data"
             } = json_response(conn, 200)["data"]
    end

    test "renders errors when data is invalid", %{conn: conn} do
      {:ok, paste} = Pastes.create_paste(%{data: "some data"})

      conn = patch(conn, ~p"/api/v1/pastes/#{paste.id}", paste: @invalid_attrs)

      assert %{"data" => [_]} = json_response(conn, 422)["errors"]
    end

    test "rejects data over the configured size limit", %{conn: conn} do
      {:ok, paste} = Pastes.create_paste(%{data: "some data"})
      too_large_data = String.duplicate("a", @max_paste_bytes + 1)

      conn = patch(conn, ~p"/api/v1/pastes/#{paste.id}", %{data: too_large_data})

      assert %{
               "errors" => %{
                 "detail" => "Paste data exceeds the maximum size of 1048576 bytes"
               }
             } = json_response(conn, 413)
    end
  end

  describe "delete paste" do
    test "deletes chosen paste", %{conn: conn} do
      {:ok, paste} = Pastes.create_paste(%{data: "some data"})

      conn = delete(conn, ~p"/api/v1/pastes/#{paste.id}")

      assert response(conn, 204)
      assert_raise Ecto.NoResultsError, fn -> Pastes.get_paste!(paste.id) end
    end
  end

  defp assert_millisecond_timestamp(timestamp) do
    assert timestamp =~ ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/
  end

  defp put_max_paste_bytes(max_paste_bytes) do
    previous_max_paste_bytes = Application.get_env(:textbin, :max_paste_bytes)
    Application.put_env(:textbin, :max_paste_bytes, max_paste_bytes)

    on_exit(fn ->
      Application.put_env(:textbin, :max_paste_bytes, previous_max_paste_bytes)
    end)
  end
end
