defmodule TextbinWeb.ApiV1.PasteJSON do
  alias Textbin.Pastes.Paste

  def index(%{pastes: pastes}) do
    %{data: for(paste <- pastes, do: data(paste))}
  end

  def create(%{paste: paste}) do
    %{data: data(paste) |> Map.delete(:data)}
  end

  def show(%{paste: paste}) do
    %{data: data(paste)}
  end

  defp data(%Paste{} = paste) do
    %{
      id: paste.id,
      data: paste.data,
      syntax_highlight: paste.syntax_highlight,
      expires_at: timestamp(paste.expires_at),
      inserted_at: timestamp(paste.inserted_at),
      updated_at: timestamp(paste.updated_at)
    }
  end

  defp timestamp(nil), do: nil

  # Keep timestamps serialized at milliseconds; clients should not observe
  # adapter-specific microsecond padding.
  defp timestamp(%DateTime{} = timestamp) do
    timestamp
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end
end
