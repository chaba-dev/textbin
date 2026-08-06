defmodule TextbinWeb.UI.PasteLive do
  use TextbinWeb, :live_view

  alias Textbin.Accounts.{Scope, User}
  alias Textbin.Pastes
  alias Textbin.Pastes.ContentType
  alias Textbin.Pastes.Paste

  embed_templates "paste_live/*"

  def mount(_params, _session, socket), do: {:ok, socket}

  def handle_params(
        _params,
        _uri,
        %{assigns: %{live_action: :index, current_scope: nil}} = socket
      ) do
    {:noreply,
     socket
     |> put_flash(:error, "You must log in to access this page.")
     |> redirect(to: ~p"/users/log-in")}
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :index}} = socket) do
    {:noreply,
     socket
     |> assign_paste_form()
     |> stream(:pastes, Pastes.list_paste_metadata(socket.assigns.current_scope), reset: true)}
  end

  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :show}} = socket) do
    case Pastes.get_shared_paste(socket.assigns.current_scope, id) do
      %Paste{} = paste ->
        {:noreply,
         socket
         |> assign(:page_title, "Paste #{paste.id}")
         |> assign(:paste, paste)
         |> assign(:text_content?, text_content?(paste))
         |> assign(:owner?, owner?(socket.assigns.current_scope, paste))
         |> assign(:highlighted_paste_data, highlighted_paste_data(paste))}

      nil ->
        raise Ecto.NoResultsError, queryable: Paste
    end
  end

  def handle_event("delete", %{"id" => id}, %{assigns: %{live_action: :index}} = socket) do
    paste = Pastes.get_paste!(socket.assigns.current_scope, id)

    case Pastes.delete_paste(socket.assigns.current_scope, paste) do
      {:ok, _paste} ->
        {:noreply, stream_delete(socket, :pastes, paste)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Paste deletion could not be completed")}
    end
  end

  def handle_event("delete", %{"id" => id}, %{assigns: %{live_action: :show}} = socket) do
    paste = Pastes.get_paste!(socket.assigns.current_scope, id)

    case Pastes.delete_paste(socket.assigns.current_scope, paste) do
      {:ok, _paste} ->
        {:noreply,
         socket
         |> put_flash(:info, "Paste deleted")
         |> push_navigate(to: ~p"/pastes")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Paste deletion could not be completed")}
    end
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
    if text_content?(paste) do
      paste.data
      |> Lumis.highlight!(formatter: {:html_inline, language: highlight_language(paste)})
      |> then(&{:safe, &1})
    end
  end

  defp text_content?(paste) do
    ContentType.textual?(paste.content_type) and ContentType.text_safe?(paste.data)
  end

  defp highlight_language(%Paste{syntax_highlight: syntax_highlight})
       when is_binary(syntax_highlight) do
    case String.trim(syntax_highlight) do
      "" -> "plain"
      language -> language
    end
  end

  defp highlight_language(_paste), do: "plain"

  defp owner?(%Scope{user: %User{id: user_id}}, %Paste{user_id: user_id}), do: true
  defp owner?(_current_scope, _paste), do: false

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

  defp paste_visibility_options(%Textbin.Accounts.User{} = user) do
    if Textbin.Accounts.User.guest?(user) do
      [{"Unlisted", "unlisted"}]
    else
      [{"Private", "private"}, {"Unlisted", "unlisted"}, {"Public", "public"}]
    end
  end

  defp guest_user?(%Textbin.Accounts.User{} = user), do: Textbin.Accounts.User.guest?(user)
end
