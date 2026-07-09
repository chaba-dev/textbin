defmodule TextbinWeb.UI.PasteLive do
  use TextbinWeb, :live_view

  alias Textbin.Pastes

  embed_templates "paste_live/*"

  def mount(_params, _session, socket), do: {:ok, socket}

  def handle_params(_params, _uri, %{assigns: %{live_action: :index}} = socket) do
    {:noreply, stream(socket, :pastes, Pastes.list_pastes(), reset: true)}
  end

  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :show}} = socket) do
    {:noreply, assign(socket, :paste, Pastes.get_paste!(id))}
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
end
