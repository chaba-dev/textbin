defmodule TextbinWeb.ApiV1.PasteControllerTest do
  use TextbinWeb.ConnCase, async: false

  alias Textbin.Pastes

  @max_paste_bytes 1_048_576
  @create_attrs %{data: "some data", syntax_highlight: "elixir"}
  @invalid_attrs %{data: nil}

  describe "index" do
    test "lists all pastes", %{conn: conn} do
      {:ok, paste} = Pastes.create_paste(%{data: "some data"})

      conn = get(conn, ~p"/api/v1/pastes")

      assert conn.private.phoenix_controller == TextbinWeb.ApiV1.PasteController
      assert conn.private.phoenix_view["json"] == TextbinWeb.ApiV1.PasteJSON
      assert %{"data" => [data]} = json_response(conn, 200)
      assert data["id"] == paste.id
      assert data["syntax_highlight"] == "plain"
    end
  end

  describe "create paste" do
    test "renders paste when data is valid", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/pastes", paste: @create_attrs)

      assert %{"id" => id, "syntax_highlight" => "elixir"} =
               response_data = json_response(conn, 201)["data"]

      refute Map.has_key?(response_data, "data")
      assert_stored_paste(id, "some data", "elixir")

      conn = get(conn, ~p"/api/v1/pastes/#{id}")

      assert %{
               "id" => ^id,
               "data" => "some data",
               "syntax_highlight" => "elixir",
               "inserted_at" => inserted_at,
               "updated_at" => updated_at
             } = json_response(conn, 200)["data"]

      assert_millisecond_timestamp(inserted_at)
      assert_millisecond_timestamp(updated_at)
    end

    test "renders paste from flat JSON data", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/pastes", @create_attrs)

      assert %{"id" => id, "syntax_highlight" => "elixir"} =
               response_data = json_response(conn, 201)["data"]

      refute Map.has_key?(response_data, "data")
      assert_stored_paste(id, "some data", "elixir")
    end

    test "renders paste from JSON string body", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/v1/pastes", Jason.encode!("json string data"))

      assert %{"id" => id} = response_data = json_response(conn, 201)["data"]
      assert response_data["syntax_highlight"] == "plain"
      refute Map.has_key?(response_data, "data")
      assert_stored_paste(id, "json string data", "plain")
    end

    test "renders paste from raw request body", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post(~p"/api/v1/pastes", "streamed data")

      assert %{"id" => id} = response_data = json_response(conn, 201)["data"]
      assert response_data["syntax_highlight"] == "plain"
      refute Map.has_key?(response_data, "data")
      assert_stored_paste(id, "streamed data", "plain")
    end

    test "renders paste from raw request body with syntax highlight", %{conn: conn} do
      conn =
        conn
        |> put_req_header("content-type", "text/plain")
        |> post(~p"/api/v1/pastes?syntax_highlight=elixir", "streamed data")

      assert %{"id" => id, "syntax_highlight" => "elixir"} =
               response_data = json_response(conn, 201)["data"]

      refute Map.has_key?(response_data, "data")
      assert_stored_paste(id, "streamed data", "elixir")
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

  describe "show paste" do
    test "returns bad request when id is not a UUID", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/pastes/not-a-uuid")

      assert %{
               "errors" => %{
                 "detail" => "Paste id must be a valid UUID"
               }
             } = json_response(conn, 400)
    end

    test "returns not found when paste does not exist", %{conn: conn} do
      missing_id = "00000000-0000-0000-0000-000000000000"

      conn = get(conn, ~p"/api/v1/pastes/#{missing_id}")

      assert %{
               "errors" => %{
                 "detail" => "Paste not found"
               }
             } = json_response(conn, 404)
    end
  end

  describe "update paste" do
    test "is not routable", %{conn: conn} do
      {:ok, paste} = Pastes.create_paste(%{data: "some data"})

      conn = patch(conn, ~p"/api/v1/pastes/#{paste.id}", paste: %{data: "updated data"})

      assert response(conn, 404)
      assert_stored_paste(paste.id, "some data", "plain")
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

  defp assert_stored_paste(id, expected_data, expected_syntax_highlight) do
    paste = Pastes.get_paste!(id)

    assert paste.data == expected_data
    assert paste.syntax_highlight == expected_syntax_highlight
  end

  defp put_max_paste_bytes(max_paste_bytes) do
    previous_max_paste_bytes = Application.get_env(:textbin, :max_paste_bytes)
    Application.put_env(:textbin, :max_paste_bytes, max_paste_bytes)

    on_exit(fn ->
      Application.put_env(:textbin, :max_paste_bytes, previous_max_paste_bytes)
    end)
  end
end
