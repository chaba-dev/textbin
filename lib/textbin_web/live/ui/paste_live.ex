defmodule TextbinWeb.UI.PasteLive do
  use TextbinWeb, :live_view

  alias Textbin.Pastes
  alias Textbin.Pastes.Paste

  embed_templates "paste_live/*"

  def mount(_params, _session, socket), do: {:ok, socket}

  def handle_params(_params, _uri, %{assigns: %{live_action: :index}} = socket) do
    {:noreply, stream(socket, :pastes, Pastes.list_pastes(), reset: true)}
  end

  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :show}} = socket) do
    paste = Pastes.get_paste!(id)

    {:noreply,
     socket
     |> assign(:paste, paste)
     |> assign(:highlighted_paste_data, highlighted_paste_data(paste))}
  end

  def handle_event("delete", %{"id" => id}, %{assigns: %{live_action: :index}} = socket) do
    paste = Pastes.get_paste!(id)
    {:ok, _paste} = Pastes.delete_paste(paste)

    {:noreply, stream_delete(socket, :pastes, paste)}
  end

  def handle_event("delete", %{"id" => id}, %{assigns: %{live_action: :show}} = socket) do
    paste = Pastes.get_paste!(id)
    {:ok, _paste} = Pastes.delete_paste(paste)

    {:noreply,
     socket
     |> put_flash(:info, "Paste deleted")
     |> push_navigate(to: ~p"/pastes")}
  end

  def render(%{live_action: :show} = assigns), do: detail(assigns)
  def render(assigns), do: index(assigns)

  defp highlighted_paste_data(%Paste{} = paste) do
    paste.data
    |> Lumis.highlight!(formatter: {:html_inline, language: highlight_language(paste)})
    |> then(&{:safe, &1})
  end

  defp highlight_language(%Paste{syntax_highlight: syntax_highlight})
       when is_binary(syntax_highlight) do
    case String.trim(syntax_highlight) do
      "" -> "plain"
      language -> language
    end
  end

  defp highlight_language(_paste), do: "plain"
end
