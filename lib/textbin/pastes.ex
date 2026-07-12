defmodule Textbin.Pastes do
  @moduledoc """
  The Pastes context.
  """

  import Ecto.Query, warn: false

  alias Textbin.Pastes.Paste
  alias Textbin.Repo

  def list_pastes do
    Repo.all(from p in Paste, order_by: [desc: p.inserted_at])
  end

  def get_paste(id), do: Repo.get(Paste, id)

  def get_paste!(id), do: Repo.get!(Paste, id)

  def create_paste(attrs \\ %{}) do
    %Paste{}
    |> Paste.changeset(attrs)
    |> Repo.insert()
  end

  def delete_paste(%Paste{} = paste) do
    Repo.delete(paste)
  end

  def change_paste(%Paste{} = paste, attrs \\ %{}) do
    Paste.changeset(paste, attrs)
  end
end
