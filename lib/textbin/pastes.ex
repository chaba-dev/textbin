defmodule Textbin.Pastes do
  @moduledoc """
  The Pastes context.
  """

  import Ecto.Query, warn: false

  alias Textbin.Accounts.{Scope, User}
  alias Textbin.Pastes.Paste
  alias Textbin.Repo
  alias Textbin.Storage

  require Logger

  def list_pastes(%Scope{user: %User{id: user_id}}) do
    now = Paste.utc_now_ms()

    Repo.all(
      from p in Paste,
        where: p.user_id == ^user_id and (is_nil(p.expires_at) or p.expires_at > ^now),
        order_by: [desc: p.inserted_at]
    )
    |> Enum.map(&load_data/1)
  end

  def get_paste(%Scope{user: %User{id: user_id}}, id) do
    now = Paste.utc_now_ms()

    Repo.one(
      from p in Paste,
        where:
          p.id == ^id and p.user_id == ^user_id and
            (is_nil(p.expires_at) or p.expires_at > ^now)
    )
    |> load_data()
  end

  def get_paste!(%Scope{user: %User{id: user_id}}, id) do
    now = Paste.utc_now_ms()

    Repo.one!(
      from p in Paste,
        where:
          p.id == ^id and p.user_id == ^user_id and
            (is_nil(p.expires_at) or p.expires_at > ^now)
    )
    |> load_data()
  end

  def get_shared_paste(current_scope, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, paste_id} ->
        now = Paste.utc_now_ms()

        Paste
        |> where([paste], paste.id == ^paste_id)
        |> where([paste], is_nil(paste.expires_at) or paste.expires_at > ^now)
        |> allow_shared_access(current_scope)
        |> Repo.one()
        |> load_data()

      :error ->
        nil
    end
  end

  def get_shared_paste(_current_scope, _id), do: nil

  def create_paste(%Scope{user: %User{} = user}, attrs \\ %{}) do
    attrs = attrs_with_defaults(attrs, user)
    paste = %Paste{id: Ecto.UUID.generate(), user_id: user.id}
    changeset = Paste.changeset(paste, attrs)

    if changeset.valid? do
      store_paste(changeset)
    else
      {:error, changeset}
    end
  end

  def delete_paste(%Scope{user: %User{id: user_id}}, %Paste{user_id: user_id} = paste) do
    # Expired rows are invisible to normal reads and give cleanup a durable key
    # to retry if storage is temporarily unavailable.
    with {:ok, expired_paste} <- expire_paste(paste),
         :ok <- delete_stored_data(expired_paste) do
      Repo.delete(expired_paste)
    end
  end

  def delete_paste(%Scope{}, %Paste{}), do: {:error, :not_found}

  @doc """
  Hard-deletes one bounded batch of expired pastes and returns the number deleted.

  Rows with an expiration equal to `:now` are considered expired. The oldest
  expirations are selected first so a backlog is drained predictably.
  """
  @spec delete_expired_pastes(keyword()) :: non_neg_integer()
  def delete_expired_pastes(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &Paste.utc_now_ms/0)
    limit = Keyword.get(opts, :limit, 500)

    if !is_integer(limit) or limit <= 0 do
      raise ArgumentError, ":limit must be a positive integer"
    end

    expired_pastes =
      Repo.all(
        from p in Paste,
          where: not is_nil(p.expires_at) and p.expires_at <= ^now,
          order_by: [asc: p.expires_at, asc: p.id],
          limit: ^limit
      )

    deletable_ids =
      for paste <- expired_pastes, delete_stored_data(paste) == :ok, do: paste.id

    {deleted_count, nil} = Repo.delete_all(from p in Paste, where: p.id in ^deletable_ids)

    deleted_count
  end

  def load_data(nil), do: nil
  def load_data(%Paste{data: data} = paste) when is_binary(data), do: paste

  def load_data(%Paste{storage_key: storage_key} = paste) when is_binary(storage_key) do
    %{paste | data: Storage.get!(storage_key)}
  end

  def change_paste(%Scope{user: %User{} = user}, %Paste{} = paste, attrs \\ %{}) do
    paste = %{paste | user_id: paste.user_id || user.id}

    Paste.changeset(paste, attrs_with_visibility(attrs, user))
  end

  defp store_paste(changeset) do
    data = Ecto.Changeset.get_field(changeset, :data)
    storage_key = "pastes/#{changeset.data.id}"

    case Storage.put(storage_key, data) do
      {:ok, metadata} ->
        try do
          changeset
          |> Ecto.Changeset.put_change(:data, nil)
          |> Ecto.Changeset.put_change(:storage_key, storage_key)
          |> Ecto.Changeset.put_change(:size_bytes, metadata.size_bytes)
          |> Ecto.Changeset.put_change(:sha256, metadata.sha256)
          |> Repo.insert()
          |> finalize_insert(storage_key, data)
        rescue
          exception ->
            delete_storage_key(storage_key)
            reraise exception, __STACKTRACE__
        catch
          kind, reason ->
            delete_storage_key(storage_key)
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      {:error, reason} ->
        # A failed HTTP response can be ambiguous: the object store may have
        # committed the PUT before the connection failed.
        delete_storage_key(storage_key)
        Logger.error("Failed to store paste content: #{inspect(reason)}")
        {:error, Ecto.Changeset.add_error(changeset, :data, "could not be stored")}
    end
  end

  defp finalize_insert({:ok, paste}, _storage_key, data), do: {:ok, %{paste | data: data}}

  defp finalize_insert({:error, _changeset} = error, storage_key, _data) do
    delete_storage_key(storage_key)
    error
  end

  defp delete_stored_data(%Paste{storage_key: storage_key}), do: delete_storage_key(storage_key)

  defp expire_paste(paste) do
    paste
    |> Ecto.Changeset.change(expires_at: Paste.utc_now_ms())
    |> Repo.update()
  end

  defp delete_storage_key(nil), do: :ok

  defp delete_storage_key(storage_key) do
    case Storage.delete(storage_key) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to delete stored paste content: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp attrs_with_defaults(attrs, user) do
    attrs
    |> attrs_with_default_ttl(user)
    |> attrs_with_visibility(user)
  end

  defp attrs_with_default_ttl(attrs, user) do
    if ttl_provided?(attrs) do
      attrs
    else
      Map.put(attrs, default_ttl_key(attrs), user.default_paste_ttl || "never")
    end
  end

  defp default_ttl_key(attrs) when is_map(attrs) do
    if Enum.any?(Map.keys(attrs), &is_binary/1), do: "expires_in", else: :expires_in
  end

  defp attrs_with_visibility(attrs, %User{} = user) when is_map(attrs) do
    visibility = if User.guest?(user), do: "unlisted", else: visibility_value(attrs)

    Map.put(attrs, attr_key(attrs, "visibility", :visibility), visibility || "private")
  end

  defp visibility_value(attrs) do
    case Map.get(attrs, "visibility") || Map.get(attrs, :visibility) do
      "" -> nil
      visibility -> visibility
    end
  end

  defp attr_key(attrs, string_key, atom_key) do
    if Enum.any?(Map.keys(attrs), &is_binary/1), do: string_key, else: atom_key
  end

  defp ttl_provided?(attrs) when is_map(attrs) do
    ttl_value(attrs) not in [nil, ""]
  end

  defp ttl_provided?(_attrs), do: false

  defp ttl_value(attrs) do
    Map.get(attrs, "expires_in") || Map.get(attrs, :expires_in) || Map.get(attrs, "ttl") ||
      Map.get(attrs, :ttl)
  end

  defp allow_shared_access(query, %Scope{user: %User{id: user_id}}) do
    where(
      query,
      [paste],
      paste.user_id == ^user_id or paste.visibility in ["unlisted", "public"]
    )
  end

  defp allow_shared_access(query, nil) do
    where(query, [paste], paste.visibility in ["unlisted", "public"])
  end
end
