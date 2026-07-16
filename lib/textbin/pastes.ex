defmodule Textbin.Pastes do
  @moduledoc """
  The Pastes context.
  """

  import Ecto.Query, warn: false

  alias Textbin.Accounts.{Scope, User}
  alias Textbin.Pastes.Paste
  alias Textbin.Repo

  def list_pastes(%Scope{user: %User{id: user_id}}) do
    Repo.all(from p in Paste, where: p.user_id == ^user_id, order_by: [desc: p.inserted_at])
  end

  def get_paste(%Scope{user: %User{id: user_id}}, id) do
    Repo.get_by(Paste, id: id, user_id: user_id)
  end

  def get_paste!(%Scope{user: %User{id: user_id}}, id) do
    Repo.get_by!(Paste, id: id, user_id: user_id)
  end

  def create_paste(%Scope{user: %User{} = user}, attrs \\ %{}) do
    %Paste{user_id: user.id}
    |> Paste.changeset(attrs)
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
end
