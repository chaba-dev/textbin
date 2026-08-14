defmodule TextbinWeb.ApiV1.PasteJSON do
  alias Textbin.Pastes.ContentType
  alias Textbin.Pastes.Paste

  def index(%{pastes: pastes} = assigns) do
    %{data: for(paste <- pastes, do: data(paste, assigns))}
  end

  def create(%{paste: paste} = assigns) do
    %{data: metadata(paste, assigns)}
  end

  def show(%{paste: paste} = assigns) do
    %{data: data(paste, assigns)}
  end

  defp data(%Paste{} = paste, assigns) do
    metadata = metadata(paste, assigns)

    if ContentType.textual?(paste.content_type) and ContentType.text_safe?(paste.data) do
      Map.put(metadata, :data, paste.data)
    else
      Map.merge(metadata, %{
        data: nil,
        data_base64: Base.encode64(paste.data),
        data_encoding: "base64"
      })
    end
  end

  defp metadata(%Paste{} = paste, assigns) do
    %{
      id: paste.id,
      organization_id: assigns.organization_id,
      workspace_id: assigns.workspace_id,
      content_type: paste.content_type,
      syntax_highlight: paste.syntax_highlight,
      audience: paste.audience,
      visibility: legacy_visibility(paste.audience),
      expires_at: timestamp(paste.expires_at),
      inserted_at: timestamp(paste.inserted_at),
      updated_at: timestamp(paste.updated_at)
    }
  end

  defp legacy_visibility("workspace"), do: "private"
  defp legacy_visibility(audience), do: audience

  defp timestamp(nil), do: nil

  # Keep timestamps serialized at milliseconds; clients should not observe
  # adapter-specific microsecond padding.
  defp timestamp(%DateTime{} = timestamp) do
    timestamp
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end
end
