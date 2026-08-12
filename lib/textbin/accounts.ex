defmodule Textbin.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias Textbin.Repo

  alias Textbin.Accounts.{User, UserToken, UserNotifier}
  alias Textbin.Organizations

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  def get_user_by_email(email) when is_binary(email) do
    Repo.get_by(User, email: email)
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  def get_user_by_email_and_password(email, password)
      when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: email)
    if User.valid_password?(user, password), do: user
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id), do: Repo.get!(User, id)

  def get_guest_user(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get_by(User, id: id, kind: "guest")
      :error -> nil
    end
  end

  def get_guest_user(_id), do: nil

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> create_user_with_personal_organization()
  end

  def create_guest_user(attrs \\ %{}) do
    attrs =
      attrs
      |> normalize_guest_attrs()
      |> Map.put_new("email", guest_email())
      |> Map.put_new("default_paste_ttl", guest_paste_ttl())

    %User{}
    |> User.guest_changeset(attrs)
    |> create_user_with_personal_organization()
  end

  defp create_user_with_personal_organization(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.insert(changeset),
           {:ok, _organization} <- Organizations.create_personal_organization_in_transaction(user) do
        {:ok, user}
      end
    end)
  end

  defp normalize_guest_attrs(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, normalized when is_atom(key) ->
        Map.put_new(normalized, Atom.to_string(key), value)

      {key, value}, normalized ->
        Map.put(normalized, key, value)
    end)
  end

  defp guest_email do
    "guest-#{Ecto.UUID.generate()}@guest.textbin.local"
  end

  defp guest_paste_ttl do
    Application.get_env(:textbin, :guest_paste_ttl, "6h")
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  def sudo_mode?(user, minutes \\ -20)

  def sudo_mode?(%User{authenticated_at: ts}, minutes) when is_struct(ts, DateTime) do
    DateTime.after?(ts, DateTime.utc_now() |> DateTime.add(minutes, :minute))
  end

  def sudo_mode?(_user, _minutes), do: false

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `Textbin.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `Textbin.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing user paste defaults.
  """
  def change_user_paste_defaults(user, attrs \\ %{}) do
    User.paste_defaults_changeset(user, attrs)
  end

  @doc """
  Updates user paste defaults.
  """
  def update_user_paste_defaults(user, attrs) do
    user
    |> User.paste_defaults_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  ## Session

  @doc """
  Generates a session token.
  """
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  def deliver_user_update_email_instructions(%User{} = user, current_email, update_email_url_fun)
      when is_function(update_email_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

    Repo.insert!(user_token)
    UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  def deliver_login_instructions(%User{} = user, magic_link_url_fun)
      when is_function(magic_link_url_fun, 1) do
    {encoded_token, user_token} = UserToken.build_email_token(user, "login")
    Repo.insert!(user_token)
    UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))
  end

  @doc """
  Deletes the signed token with the given context.
  """
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## API tokens

  @doc """
  Lists API tokens for the given user.
  """
  def list_user_api_tokens(%User{} = user) do
    UserToken
    |> where(
      [token],
      token.user_id == ^user.id and token.context == ^UserToken.api_token_context()
    )
    |> order_by([token], desc: token.inserted_at)
    |> Repo.all()
  end

  @doc """
  Creates an API token for the given user.

  The raw token is returned once alongside the stored token record.
  """
  def create_user_api_token(%User{} = user, attrs \\ %{}) do
    name = api_token_name(attrs)
    {token, user_token} = UserToken.build_api_token(user, name)

    case Repo.insert(user_token) do
      {:ok, user_token} -> {:ok, {token, user_token}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Deletes a user's API token.
  """
  def delete_user_api_token(%User{} = user, token_id) when is_binary(token_id) do
    case Ecto.UUID.cast(token_id) do
      {:ok, token_id} ->
        {count, _result} =
          Repo.delete_all(
            from token in UserToken,
              where:
                token.id == ^token_id and token.user_id == ^user.id and
                  token.context == ^UserToken.api_token_context()
          )

        if count == 1, do: :ok, else: {:error, :not_found}

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Gets a user and token record by API token and records its last-used timestamp.
  """
  def get_user_and_api_token(token) when is_binary(token) do
    with {:ok, query} <- UserToken.verify_api_token_query(token),
         {user, user_token} <- Repo.one(query) do
      now = DateTime.utc_now(:second)

      Repo.update_all(
        from(token in UserToken, where: token.id == ^user_token.id),
        set: [last_used_at: now]
      )

      {user, %{user_token | last_used_at: now}}
    else
      _ -> nil
    end
  end

  @doc """
  Gets a user by API token and records the token's last-used timestamp.
  """
  def get_user_by_api_token(token) when is_binary(token) do
    case get_user_and_api_token(token) do
      {user, _user_token} -> user
      nil -> nil
    end
  end

  defp api_token_name(attrs) do
    attrs
    |> Map.get("name", "")
    |> String.trim()
    |> case do
      "" -> "API token"
      name -> String.slice(name, 0, 80)
    end
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
