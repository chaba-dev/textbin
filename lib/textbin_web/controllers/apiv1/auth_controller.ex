defmodule TextbinWeb.ApiV1.AuthController do
  use TextbinWeb, :controller

  alias Textbin.Accounts
  alias Textbin.Accounts.{Scope, User, UserToken}

  def create(conn, %{"email" => email, "password" => password} = params)
      when is_binary(email) and is_binary(password) do
    case Accounts.get_user_by_email_and_password(email, password) do
      %User{} = user -> create_token(conn, user, params)
      nil -> render_invalid_credentials(conn)
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{errors: %{detail: "Email and password are required"}})
  end

  def show(%{assigns: %{current_scope: %Scope{user: %User{} = user}}} = conn, _params) do
    user_token = conn.assigns.current_api_token
    json(conn, %{data: identity_data(user, user_token)})
  end

  def delete(
        %{assigns: %{current_scope: %Scope{user: %User{} = user}, current_api_token: user_token}} =
          conn,
        _params
      ) do
    case Accounts.delete_user_api_token(user, user_token.id) do
      :ok -> send_resp(conn, :no_content, "")
      {:error, :not_found} -> send_resp(conn, :no_content, "")
    end
  end

  defp create_token(conn, user, params) do
    name =
      case Map.get(params, "name") do
        name when is_binary(name) -> name
        _name -> "Textbin CLI"
      end

    case Accounts.create_user_api_token(user, %{"name" => name}) do
      {:ok, {token, user_token}} ->
        conn
        |> put_status(:created)
        |> json(%{data: Map.put(identity_data(user, user_token), :api_token, token)})

      {:error, _changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{detail: "Could not create API token"}})
    end
  end

  defp identity_data(user, %UserToken{} = user_token) do
    %{
      user: %{id: user.id, email: user.email},
      token: %{
        id: user_token.id,
        name: user_token.name,
        inserted_at: DateTime.to_iso8601(user_token.inserted_at)
      }
    }
  end

  defp render_invalid_credentials(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{errors: %{detail: "Invalid email or password"}})
  end
end
