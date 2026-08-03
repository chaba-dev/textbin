defmodule TextbinWeb.UI.PasteLive do
  use TextbinWeb, :live_view

  alias Textbin.Pastes
  alias Textbin.Pastes.Paste

  embed_templates "paste_live/*"

  def mount(_params, _session, socket), do: {:ok, socket}

  def handle_params(_params, _uri, %{assigns: %{current_scope: nil}} = socket) do
    {:noreply,
     socket
     |> put_flash(:error, "You must log in to access this page.")
     |> redirect(to: ~p"/users/log-in")}
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :index}} = socket) do
    {:noreply,
     socket
     |> assign_paste_form()
     |> stream(:pastes, Pastes.list_pastes(socket.assigns.current_scope), reset: true)}
  end

  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :show}} = socket) do
    paste = Pastes.get_paste!(socket.assigns.current_scope, id)

    {:noreply,
     socket
     |> assign(:paste, paste)
     |> assign(:highlighted_paste_data, highlighted_paste_data(paste))}
  end

  def handle_event("delete", %{"id" => id}, %{assigns: %{live_action: :index}} = socket) do
    paste = Pastes.get_paste!(socket.assigns.current_scope, id)
    {:ok, _paste} = Pastes.delete_paste(socket.assigns.current_scope, paste)

    {:noreply, stream_delete(socket, :pastes, paste)}
  end

  def handle_event("delete", %{"id" => id}, %{assigns: %{live_action: :show}} = socket) do
    paste = Pastes.get_paste!(socket.assigns.current_scope, id)
    {:ok, _paste} = Pastes.delete_paste(socket.assigns.current_scope, paste)

    {:noreply,
     socket
     |> put_flash(:info, "Paste deleted")
     |> push_navigate(to: ~p"/pastes")}
  end

  def handle_event("validate", %{"paste" => paste_params}, socket) do
    form =
      socket.assigns.current_scope
      |> Pastes.change_paste(%Paste{}, paste_params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :paste_form, form)}
  end

  def handle_event("save", %{"paste" => paste_params}, socket) do
    case Pastes.create_paste(socket.assigns.current_scope, paste_params) do
      {:ok, paste} ->
        {:noreply,
         socket
         |> put_flash(:info, "Paste created")
         |> assign_paste_form()
         |> stream_insert(:pastes, paste, at: 0)}

      {:error, changeset} ->
        {:noreply, assign(socket, :paste_form, to_form(changeset, action: :insert))}
    end
  end

  def render(%{live_action: :show} = assigns), do: detail(assigns)
  def render(assigns), do: index(assigns)

  defp assign_paste_form(socket) do
    form =
      socket.assigns.current_scope
      |> Pastes.change_paste(%Paste{})
      |> to_form()

    assign(socket, :paste_form, form)
  end

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

  defp paste_ttl_options do
    [
      {"Use account default", ""},
      {"Never", "never"},
      {"10 minutes", "10m"},
      {"1 hour", "1h"},
      {"6 hours", "6h"},
      {"12 hours", "12h"},
      {"1 day", "1d"},
      {"7 days", "7d"},
      {"30 days", "30d"}
    ]
  end
end
