defmodule TextbinWeb.ApiV1.AuthControllerTest do
  use TextbinWeb.ConnCase, async: true

  alias Textbin.Accounts
  alias Textbin.Accounts.UserToken
  alias Textbin.Repo

  import Textbin.AccountsFixtures

  # The API accepts JSON bodies only.
  setup %{conn: conn}, do: %{conn: json_conn(conn)}

  setup do
    user = user_fixture() |> set_password()
    %{user: user}
  end

  describe "create token" do
    test "rejects _json wrappers rather than validating different credentials", %{
      conn: conn,
      user: user
    } do
      credentials = %{email: user.email, password: valid_user_password()}

      for body <- [
            %{_json: credentials},
            Map.merge(credentials, %{_json: credentials, surprise: true}),
            %{_json: credentials, email: 12, password: false}
          ] do
        assert conn
               |> post(~p"/api/v1/auth/tokens", Jason.encode!(body))
               |> json_response(422)
      end
    end

    test "creates and returns a named token from valid credentials", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/api/v1/auth/tokens", %{
          email: user.email,
          password: valid_user_password(),
          name: "Laptop CLI"
        })

      assert %{
               "api_token" => "txb_" <> _ = token,
               "user" => %{"id" => user_id, "email" => email},
               "token" => %{"id" => token_id, "name" => "Laptop CLI"}
             } = json_response(conn, 201)["data"]

      assert user_id == user.id
      assert email == user.email
      assert Accounts.get_user_by_api_token(token).id == user.id
      assert Repo.get!(UserToken, token_id).user_id == user.id
    end

    test "does not reveal whether the email or password was incorrect", %{conn: conn, user: user} do
      for params <- [
            %{email: user.email, password: "incorrect password"},
            %{email: "missing@example.com", password: valid_user_password()}
          ] do
        conn = post(conn, ~p"/api/v1/auth/tokens", params)

        assert %{"errors" => %{"detail" => "Invalid email or password"}} =
                 json_response(conn, 401)
      end
    end

    test "requires email and password", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/auth/tokens", %{})

      assert %{"errors" => %{"email" => [_], "password" => [_]}} = json_response(conn, 422)
    end

    test "rejects a name that is not a string", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/api/v1/auth/tokens", %{
          email: user.email,
          password: valid_user_password(),
          name: %{unexpected: "value"}
        })

      assert %{"errors" => %{"name" => [_]}} = json_response(conn, 422)
    end

    test "uses the default token name when none is given", %{conn: conn, user: user} do
      conn =
        post(conn, ~p"/api/v1/auth/tokens", %{email: user.email, password: valid_user_password()})

      assert %{"token" => %{"name" => "Textbin CLI"}} = json_response(conn, 201)["data"]
    end
  end

  describe "current identity" do
    setup %{conn: conn, user: user} do
      {:ok, {token, user_token}} = Accounts.create_user_api_token(user, %{"name" => "CLI"})

      %{
        conn: put_req_header(json_conn(conn), "authorization", "Bearer #{token}"),
        token: token,
        user_token: user_token
      }
    end

    test "returns the current user and token metadata", %{
      conn: conn,
      user: user,
      user_token: user_token
    } do
      conn = get(conn, ~p"/api/v1/me")

      assert %{
               "user" => %{"id" => user_id, "email" => email},
               "token" => %{"id" => token_id, "name" => "CLI"}
             } = data = json_response(conn, 200)["data"]

      assert user_id == user.id
      assert email == user.email
      assert token_id == user_token.id
      refute Map.has_key?(data, "api_token")
    end

    test "requires an API token" do
      conn = get(json_conn(), ~p"/api/v1/me")

      assert %{"errors" => %{"detail" => "API token required"}} = json_response(conn, 401)
    end

    test "revokes the current API token", %{conn: conn, token: token, user_token: user_token} do
      conn = delete(conn, ~p"/api/v1/me/token")

      assert response(conn, 204) == ""
      refute Repo.get(UserToken, user_token.id)

      conn =
        json_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> get(~p"/api/v1/me")

      assert %{"errors" => %{"detail" => "Invalid API token"}} = json_response(conn, 401)
    end

    test "concurrent revocation is idempotent", %{user: user, user_token: user_token} do
      revoke = fn ->
        json_conn()
        |> Plug.Conn.assign(:current_scope, Accounts.Scope.for_user(user))
        |> Plug.Conn.assign(:current_api_token, user_token)
        |> TextbinWeb.ApiV1.AuthController.delete(%{})
      end

      assert response(revoke.(), 204) == ""
      assert response(revoke.(), 204) == ""
    end
  end
end
