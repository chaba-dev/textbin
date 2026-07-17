defmodule Textbin.Pastes do
  @moduledoc """
  The Pastes context.
  """

  import Ecto.Query, warn: false

  alias Textbin.Accounts.{Scope, User}
  alias Textbin.Pastes.Paste
  alias Textbin.Repo

  def list_pastes(%Scope{user: %User{id: user_id}}) do
    now = Paste.utc_now_ms()

    Repo.all(
      from p in Paste,
        where: p.user_id == ^user_id and (is_nil(p.expires_at) or p.expires_at > ^now),
        order_by: [desc: p.inserted_at]
    )
  end

  def get_paste(%Scope{user: %User{id: user_id}}, id) do
    now = Paste.utc_now_ms()

    Repo.one(
      from p in Paste,
        where:
          p.id == ^id and p.user_id == ^user_id and
            (is_nil(p.expires_at) or p.expires_at > ^now)
    )
  end

  def get_paste!(%Scope{user: %User{id: user_id}}, id) do
    now = Paste.utc_now_ms()

    Repo.one!(
      from p in Paste,
        where:
          p.id == ^id and p.user_id == ^user_id and
            (is_nil(p.expires_at) or p.expires_at > ^now)
    )
  end

  def create_paste(%Scope{user: %User{} = user}, attrs \\ %{}) do
    %Paste{user_id: user.id}
    |> Paste.changeset(attrs_with_default_ttl(attrs, user))
    |> Repo.insert()
  end

  def delete_paste(%Scope{user: %User{id: user_id}}, %Paste{user_id: user_id} = paste) do
    Repo.delete(paste)
  end

  def delete_paste(%Scope{}, %Paste{}), do: {:error, :not_found}

  def change_paste(%Scope{user: %User{} = user}, %Paste{} = paste, attrs \\ %{}) do
    paste = %{paste | user_id: paste.user_id || user.id}

    Paste.changeset(paste, attrs)
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

  defp ttl_provided?(attrs) when is_map(attrs) do
    Map.has_key?(attrs, "expires_in") or Map.has_key?(attrs, :expires_in) or
      Map.has_key?(attrs, "ttl") or Map.has_key?(attrs, :ttl)
  end

  defp ttl_provided?(_attrs), do: false
end
