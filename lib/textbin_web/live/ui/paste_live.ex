defmodule TextbinWeb.UI.PasteLive do
  use TextbinWeb, :live_view

  alias Textbin.Organizations
  alias Textbin.Organizations.Policy
  alias Textbin.Pastes
  alias Textbin.Pastes.ContentType
  alias Textbin.Pastes.Paste

  embed_templates "paste_live/*"

  def mount(_params, _session, socket), do: {:ok, socket}

  def handle_params(
        _params,
        _uri,
        %{assigns: %{live_action: :legacy_index, current_scope: nil}} = socket
      ) do
    {:noreply,
     socket
     |> put_flash(:error, "You must log in to access this page.")
     |> redirect(to: ~p"/users/log-in")}
  end

  def handle_params(_params, _uri, %{assigns: %{live_action: :legacy_index}} = socket) do
    organization = Organizations.get_personal_organization!(socket.assigns.current_scope.user)
    workspace = Enum.find(organization.workspaces, & &1.is_default)

    {:noreply,
     push_navigate(socket,
       to: workspace_pastes_path(organization.slug, workspace.slug)
     )}
  end

  def handle_params(
        %{"organization_slug" => organization_slug, "workspace_slug" => workspace_slug},
        _uri,
        %{assigns: %{live_action: :workspace_index}} = socket
      ) do
    scope =
      resolve_workspace_scope!(socket.assigns.current_scope, organization_slug, workspace_slug)

    {:noreply,
     socket
     |> assign_workspace_navigation(scope)
     |> assign_paste_form()
     |> stream(:pastes, Pastes.list_paste_metadata(scope), reset: true)}
  end

  def handle_params(
        %{
          "organization_slug" => organization_slug,
          "workspace_slug" => workspace_slug,
          "id" => id
        },
        _uri,
        %{assigns: %{live_action: :workspace_show}} = socket
      ) do
    scope =
      resolve_workspace_scope!(socket.assigns.current_scope, organization_slug, workspace_slug)

    case Pastes.get_paste(scope, id) do
      %Paste{} = paste -> show_paste(socket, scope, paste)
      nil -> raise Ecto.NoResultsError, queryable: Paste
    end
  end

  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :show}} = socket) do
    case Pastes.get_shared_paste(socket.assigns.current_scope, id) do
      %Paste{} = paste ->
        scope = resolve_shared_paste_scope(socket.assigns.current_scope, paste)
        show_paste(socket, scope, paste)

      nil ->
        raise Ecto.NoResultsError, queryable: Paste
    end
  end

  def handle_event("delete", %{"id" => id}, %{assigns: %{live_action: :workspace_index}} = socket) do
    case Pastes.delete_paste(socket.assigns.current_scope, %Paste{id: id}) do
      {:ok, paste} ->
        {:noreply, stream_delete(socket, :pastes, paste)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Paste deletion could not be completed")}
    end
  end

  def handle_event(
        "delete",
        %{"id" => id},
        %{assigns: %{live_action: action}} = socket
      )
      when action in [:show, :workspace_show] do
    with true <- socket.assigns.paste.id == id,
         {:ok, _paste} <- Pastes.delete_paste(socket.assigns.current_scope, socket.assigns.paste) do
      {:noreply,
       socket
       |> put_flash(:info, "Paste deleted")
       |> push_navigate(to: paste_index_path(socket.assigns.current_scope))}
    else
      _error -> {:noreply, put_flash(socket, :error, "Paste deletion could not be completed")}
    end
  end

  def handle_event("validate", %{"paste" => paste_params}, socket) do
    form =
      socket.assigns.current_scope
      |> Pastes.change_paste(socket.assigns.new_paste, paste_params)
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

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Workspace is no longer available")
         |> push_navigate(to: ~p"/pastes")}

      {:error, changeset} ->
        {:noreply, assign(socket, :paste_form, to_form(changeset, action: :insert))}
    end
  end

  def render(%{live_action: action} = assigns) when action in [:show, :workspace_show],
    do: detail(assigns)

  def render(assigns), do: index(assigns)

  defp resolve_workspace_scope!(scope, organization_slug, workspace_slug) do
    case Organizations.resolve_workspace_scope_by_slugs(scope, organization_slug, workspace_slug) do
      {:ok, resolved_scope} ->
        resolved_scope

      {:error, :not_found} ->
        raise Ecto.NoResultsError, queryable: Textbin.Organizations.Workspace
    end
  end

  defp assign_workspace_navigation(socket, scope) do
    socket
    |> assign(:current_scope, scope)
    |> assign(:navigation_workspaces, navigation_workspaces(scope))
  end

  defp show_paste(socket, scope, paste) do
    {:noreply,
     socket
     |> assign(:current_scope, scope)
     |> assign(:navigation_workspaces, navigation_workspaces(scope))
     |> assign(:page_title, "Paste #{paste.id}")
     |> assign(:paste, paste)
     |> assign(:text_content?, text_content?(paste))
     |> assign(:owner?, Pastes.manage_paste?(scope, paste))
     |> assign(:highlighted_paste_data, highlighted_paste_data(paste))}
  end

  defp workspace_pastes_path(organization_slug, workspace_slug),
    do: "/w/#{organization_slug}/#{workspace_slug}/pastes"

  defp paste_index_path(%{organization: organization, workspace: workspace})
       when not is_nil(organization) and not is_nil(workspace),
       do: workspace_pastes_path(organization.slug, workspace.slug)

  defp paste_index_path(_scope), do: ~p"/pastes"

  defp resolve_shared_paste_scope(nil, _paste), do: nil

  defp resolve_shared_paste_scope(scope, paste) do
    case Organizations.resolve_workspace_scope(scope, paste.workspace_id) do
      {:ok, resolved_scope} -> resolved_scope
      {:error, :not_found} -> scope
    end
  end

  defp navigation_workspaces(%{organization: organization} = scope)
       when not is_nil(organization),
       do: Organizations.list_joined_workspaces(scope, organization)

  defp navigation_workspaces(_scope), do: []

  defp assign_paste_form(socket) do
    new_paste = Pastes.prepare_paste(socket.assigns.current_scope)

    form =
      socket.assigns.current_scope
      |> Pastes.change_paste(new_paste)
      |> to_form()

    socket
    |> assign(:new_paste, new_paste)
    |> assign(:paste_form, form)
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

  defp paste_audience_options(scope) do
    if Textbin.Accounts.User.guest?(scope.user) do
      [{"Unlisted", "unlisted"}]
    else
      case scope.workspace.external_sharing_policy do
        "disabled" -> [{"Workspace", "workspace"}]
        "unlisted" -> [{"Workspace", "workspace"}, {"Unlisted", "unlisted"}]
        "public" -> [{"Workspace", "workspace"}, {"Unlisted", "unlisted"}, {"Public", "public"}]
      end
    end
  end

  defp guest_user?(%Textbin.Accounts.User{} = user), do: Textbin.Accounts.User.guest?(user)

  defp workspace_paste_manageable?(scope, paste) do
    Policy.workspace_owner?(scope.workspace_membership) or
      paste.created_by_user_id == scope.user.id
  end
end
