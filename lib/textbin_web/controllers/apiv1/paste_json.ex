defmodule TextbinWeb.ApiV1.PasteJSON do
  use TextbinWeb, :verified_routes

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

  def restored(%{paste: paste} = assigns) do
    %{data: metadata(paste, assigns)}
  end

  # Removed pastes never include content; restore one to read it again.
  def deleted(%{pastes: pastes, recovery_window_days: window_days} = assigns) do
    %{
      data:
        for paste <- pastes do
          removed_on = Paste.removed_on(paste)

          paste
          |> metadata(assigns)
          |> Map.merge(%{
            removed_at: timestamp(removed_on),
            removal_reason: Paste.removal_reason(paste),
            purge_after: timestamp(DateTime.add(removed_on, window_days, :day))
          })
        end
    }
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
      # The browser link people share, and the exact stored bytes. Both are
      # absolute so CLI and script output can be pasted anywhere.
      url: url(~p"/pastes/#{paste.id}"),
      raw_url: url(~p"/pastes/#{paste.id}/raw"),
      organization_id: assigns.organization_id,
      workspace_id: assigns.workspace_id,
      title: paste.title,
      reference_url: paste.reference_url,
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
