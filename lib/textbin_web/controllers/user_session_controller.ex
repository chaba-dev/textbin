defmodule TextbinWeb.UserSessionController do
  use TextbinWeb, :controller

  alias Textbin.Accounts
  alias TextbinWeb.UserAuth

  def create(conn, %{"_action" => "confirmed"} = params) do
    create(conn, params, "User confirmed successfully.")
  end

  def create(conn, params) do
    create(conn, params, "Welcome back!")
  end

  # magic link login
  defp create(conn, %{"user" => %{"token" => token} = user_params}, info) do
    case Accounts.login_user_by_magic_link(token) do
      {:ok, {user, tokens_to_disconnect}} ->
        UserAuth.disconnect_sessions(tokens_to_disconnect)

        conn
        |> put_flash(:info, info)
        |> UserAuth.log_in_user(user, user_params)

      _ ->
        conn
        |> put_flash(:error, "The link is invalid or it has expired.")
        |> redirect(to: ~p"/users/log-in")
    end
  end

  # email + password login
  defp create(conn, %{"user" => user_params}, info) do
    %{"email" => email, "password" => password} = user_params

    if user = Accounts.get_user_by_email_and_password(email, password) do
      conn
      |> put_flash(:info, info)
      |> UserAuth.log_in_user(user, user_params)
    else
      # In order to prevent user enumeration attacks, don't disclose whether the email is registered.
      conn
      |> put_flash(:error, "Invalid email or password")
      |> put_flash(:email, String.slice(email, 0, 160))
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def update_password(conn, %{"user" => user_params}) do
    user = conn.assigns.current_scope.user

    if Accounts.sudo_mode?(user) do
      case Accounts.update_user_password(user, user_params) do
        {:ok, {updated_user, expired_tokens}} ->
          # The password change itself establishes fresh authentication without
          # trusting client-posted identity fields to look the user up again.
          updated_user = %{updated_user | authenticated_at: DateTime.utc_now(:second)}
          UserAuth.disconnect_sessions(expired_tokens)

          conn
          |> put_flash(:info, "Password updated successfully!")
          |> put_session(:user_return_to, ~p"/users/settings")
          |> UserAuth.log_in_user(updated_user, %{})

        {:error, _changeset} ->
          conn
          |> put_flash(:error, "Could not update password.")
          |> redirect(to: ~p"/users/settings")
      end
    else
      conn
      |> put_flash(:error, "You must re-authenticate to change sensitive account settings.")
      |> redirect(to: ~p"/users/log-in")
    end
  end

  def delete(conn, _params) do
    conn
    |> put_flash(:info, "Logged out successfully.")
    |> UserAuth.log_out_user()
  end
end
