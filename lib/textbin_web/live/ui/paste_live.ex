defmodule TextbinWeb.UI.PasteLive do
  use TextbinWeb, :live_view

  alias Textbin.Accounts
  alias Textbin.Accounts.User
  alias Textbin.Organizations
  alias Textbin.Organizations.Policy
  alias Textbin.Pastes
  alias Textbin.Pastes.ContentType
  alias Textbin.Pastes.Paste
  alias TextbinWeb.UI.Removal

  embed_templates "paste_live/*"

  @expiry_options [
    {"Never", "never"},
    {"10 min", "10m"},
    {"1 hour", "1h"},
    {"6 hours", "6h"},
    {"12 hours", "12h"},
    {"1 day", "1d"},
    {"7 days", "7d"},
    {"30 days", "30d"}
  ]

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
    {:ok, %{organization: organization, workspace: workspace}} =
      Organizations.resolve_home_scope(socket.assigns.current_scope)

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
     |> assign(:page_title, "Pastes · #{scope.workspace.name}")
     |> stream(:pastes, Pastes.list_paste_metadata(scope), reset: true)}
  end

  def handle_params(
        %{"organization_slug" => organization_slug, "workspace_slug" => workspace_slug} = params,
        _uri,
        %{assigns: %{live_action: :new}} = socket
      ) do
    scope =
      resolve_workspace_scope!(socket.assigns.current_scope, organization_slug, workspace_slug)

    {:noreply,
     socket
     |> assign_workspace_navigation(scope)
     |> assign(:page_title, "New paste · #{scope.workspace.name}")
     |> assign_paste_form(duplicate_attrs(scope, params["from"]))}
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
      nil -> show_removed_paste!(socket, scope, id)
    end
  end

  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :show}} = socket) do
    case Pastes.get_shared_paste(socket.assigns.current_scope, id) do
      %Paste{} = paste ->
        scope = resolve_shared_paste_scope(socket.assigns.current_scope, paste)
        show_paste(socket, scope, paste)

      nil ->
        show_removed_shared_paste!(socket, id)
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
       |> put_flash(:info, deleted_message(socket.assigns.current_scope))
       |> push_navigate(to: paste_index_path(socket.assigns.current_scope))}
    else
      _error -> {:noreply, put_flash(socket, :error, "Paste deletion could not be completed")}
    end
  end

  def handle_event("restore", _params, %{assigns: %{removed_paste: %Paste{} = paste}} = socket) do
    scope = socket.assigns.current_scope

    case Pastes.restore_paste(scope, paste.id) do
      {:ok, restored} ->
        {:noreply,
         socket
         |> put_flash(:info, "Paste restored")
         |> push_navigate(to: paste_path(scope, restored))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That paste can no longer be restored")}
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
    scope = socket.assigns.current_scope

    case Pastes.create_paste(scope, paste_params) do
      {:ok, paste} ->
        {:noreply,
         socket
         |> put_flash(:info, "Paste created")
         |> push_navigate(to: paste_path(scope, paste))}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, "Workspace is no longer available")
         |> push_navigate(to: ~p"/pastes")}

      {:error, changeset} ->
        {:noreply, assign(socket, :paste_form, to_form(changeset, action: :insert))}
    end
  end

  def render(%{removed_paste: %Paste{}} = assigns), do: removed(assigns)

  def render(%{live_action: action} = assigns) when action in [:show, :workspace_show],
    do: detail(assigns)

  def render(%{live_action: :new} = assigns), do: new(assigns)

  def render(assigns), do: index(assigns)

  # Every workspace page reached by its URL becomes the one home reopens.
  defp resolve_workspace_scope!(scope, organization_slug, workspace_slug) do
    case Organizations.resolve_workspace_scope_by_slugs(scope, organization_slug, workspace_slug) do
      {:ok, resolved_scope} ->
        :ok = Accounts.remember_last_workspace(resolved_scope.user, resolved_scope.workspace.id)
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

  # A removed paste's link stops working for everyone, but the people who can
  # restore it land on a page that offers to. Everyone else gets a 404.
  defp show_removed_paste!(socket, scope, id) do
    case Pastes.get_removed_paste(scope, id) do
      %Paste{} = paste ->
        {:noreply,
         socket
         |> assign(:current_scope, scope)
         |> assign(:navigation_workspaces, navigation_workspaces(scope))
         |> assign(:page_title, "Removed · #{Paste.display_title(paste)}")
         |> assign(:removed_paste, paste)}

      nil ->
        raise Ecto.NoResultsError, queryable: Paste
    end
  end

  defp show_removed_shared_paste!(socket, id) do
    current_scope = socket.assigns.current_scope

    with workspace_id when is_binary(workspace_id) <-
           Pastes.removed_paste_workspace_id(current_scope, id),
         {:ok, scope} <- Organizations.resolve_workspace_scope(current_scope, workspace_id) do
      show_removed_paste!(socket, scope, id)
    else
      _not_restorable -> raise Ecto.NoResultsError, queryable: Paste
    end
  end

  defp deleted_message(%{workspace: %{recovery_window_days: days}}),
    do: "Paste deleted. You can restore it from Deleted for #{days} days."

  defp deleted_message(_scope), do: "Paste deleted"

  defp show_paste(socket, scope, paste) do
    paste = Pastes.preload_author(paste)

    {:noreply,
     socket
     |> assign(:removed_paste, nil)
     |> assign(:current_scope, scope)
     |> assign(:navigation_workspaces, navigation_workspaces(scope))
     |> assign(:page_title, Paste.display_title(paste))
     |> assign(:paste, paste)
     |> assign(:share_url, url(~p"/pastes/#{paste.id}"))
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

  defp paste_path(scope, %Paste{id: id}), do: "#{paste_index_path(scope)}/#{id}"

  defp new_paste_path(scope), do: "#{paste_index_path(scope)}/new"

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

  # Sharing content does not share an account's email. Workspace scopes are
  # resolved through membership authorization before reaching this label.
  defp author_label(%Paste{created_by_user: %User{id: id} = user} = paste, scope) do
    cond do
      match?(%{user: %User{id: ^id}}, scope) ->
        "You"

      User.guest?(user) ->
        "Guest"

      match?(%{workspace: %{id: workspace_id}} when workspace_id == paste.workspace_id, scope) ->
        user.email

      true ->
        "Registered user"
    end
  end

  defp author_label(_paste, _scope), do: "Unknown"

  # The editor opens with the account's default expiry already selected so the
  # removal date is spelled out before anything is typed.
  defp assign_paste_form(socket, attrs) do
    scope = socket.assigns.current_scope
    new_paste = Pastes.prepare_paste(scope)
    attrs = Map.put_new(attrs, "expires_in", scope.user.default_paste_ttl || "never")

    form =
      scope
      |> Pastes.change_paste(new_paste, attrs)
      |> to_form()

    socket
    |> assign(:new_paste, new_paste)
    |> assign(:paste_form, form)
  end

  # Duplicating copies what the person could already read in this workspace;
  # binary content is left out because the editor only takes text.
  defp duplicate_attrs(_scope, nil), do: %{}

  defp duplicate_attrs(scope, source_id) do
    case Pastes.get_paste(scope, source_id) do
      %Paste{} = source ->
        %{
          "title" => source.title,
          "reference_url" => source.reference_url,
          "syntax_highlight" => source.syntax_highlight,
          "audience" => source.audience,
          "data" => if(text_content?(source), do: source.data)
        }

      nil ->
        %{}
    end
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

  defp expiry_options, do: @expiry_options

  # Every audience is listed so the policy is visible; the ones the workspace
  # forbids stay disabled with the reason instead of silently disappearing.
  defp audience_options(scope) do
    if User.guest?(scope.user) do
      [audience_option("unlisted", true)]
    else
      policy = scope.workspace.external_sharing_policy

      [
        audience_option("workspace", true),
        audience_option("unlisted", policy in ["unlisted", "public"]),
        audience_option("public", policy == "public")
      ]
    end
  end

  defp audience_option("workspace", allowed?),
    do: %{
      value: "workspace",
      label: "Workspace",
      description: "Everyone in the workspace",
      allowed?: allowed?
    }

  defp audience_option("unlisted", allowed?),
    do: %{
      value: "unlisted",
      label: "Anyone with the link",
      description: "Not listed anywhere; the link is the key",
      allowed?: allowed?
    }

  defp audience_option("public", allowed?),
    do: %{
      value: "public",
      label: "Public",
      description: "Open to everyone",
      allowed?: allowed?
    }

  defp audience_sentence(%Paste{audience: "workspace"}, %{workspace: %{name: name}}),
    do: "Everyone in #{name} can see this paste."

  defp audience_sentence(%Paste{audience: "workspace"}, _scope),
    do: "Everyone in the workspace can see this paste."

  defp audience_sentence(%Paste{audience: "unlisted"}, _scope),
    do: "Anyone with the link can see this paste."

  defp audience_sentence(%Paste{audience: "public"}, _scope), do: "This paste is public."

  defp expiry_sentence(nil), do: "It never expires."

  defp expiry_sentence(%DateTime{} = expires_at),
    do: "It is removed on #{format_date(expires_at)}."

  defp removal_sentence(%Phoenix.HTML.Form{source: %Ecto.Changeset{} = changeset}) do
    case Ecto.Changeset.get_field(changeset, :expires_at) do
      nil -> "Kept until someone deletes it."
      %DateTime{} = expires_at -> "Removed on #{format_date(expires_at)}."
    end
  end

  defp removal_sentence(_form), do: "Kept until someone deletes it."

  defp format_date(%DateTime{} = datetime),
    do: Calendar.strftime(datetime, "%b %-d, %Y at %H:%M UTC")

  defp field_errors(%Phoenix.HTML.FormField{} = field) do
    if Phoenix.Component.used_input?(field) do
      Enum.map(field.errors, &translate_error/1)
    else
      []
    end
  end

  defp workspace_paste_manageable?(scope, paste) do
    Policy.workspace_owner?(scope.workspace_membership) or
      paste.created_by_user_id == scope.user.id
  end

  defp workspace_member?(%{workspace: %{id: _id}}), do: true
  defp workspace_member?(_scope), do: false
end
