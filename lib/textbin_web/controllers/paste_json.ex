defmodule TextbinWeb.PasteJSON do
  alias Textbin.Pastes.Paste

  def index(%{pastes: pastes}) do
    %{data: for(paste <- pastes, do: data(paste))}
  end

  def show(%{paste: paste}) do
    %{data: data(paste)}
  end

  defp data(%Paste{} = paste) do
    %{
      id: paste.id,
      content: paste.content,
      inserted_at: timestamp(paste.inserted_at),
      updated_at: timestamp(paste.updated_at)
    }
  end

  defp timestamp(nil), do: nil

  defp timestamp(%DateTime{} = timestamp) do
    timestamp
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end
end
