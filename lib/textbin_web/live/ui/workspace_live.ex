defmodule TextbinWeb.UI.WorkspaceLive do
  use TextbinWeb, :live_view

  alias Textbin.Accounts
  alias Textbin.Organizations
  alias Textbin.Organizations.{Policy, Workspace, WorkspaceMembership}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(
        %{"organization_slug" => organization_slug, "workspace_slug" => workspace_slug},
        _uri,
        socket
      ) do
    scope =
      resolve_workspace_scope!(socket.assigns.current_scope, organization_slug, workspace_slug)

    {:noreply,
     socket
     |> assign(:current_scope, scope)
     |> assign(:workspace_owner?, Policy.workspace_owner?(scope.workspace_membership))
     |> assign(:member_form, to_form(%{"email" => ""}, as: :member))
     |> assign(
       :settings_form,
       to_form(%{"visibility" => scope.workspace.visibility}, as: :workspace)
     )
     |> stream(:members, Organizations.list_workspace_members(scope), reset: true)}
  end

  @impl true
  def handle_event("add_member", %{"member" => %{"email" => email}}, socket) do
    with %{} = user <- Accounts.get_user_by_email(String.trim(email)),
         {:ok, membership} <-
           Organizations.add_workspace_member(
             socket.assigns.current_scope,
             socket.assigns.current_scope.workspace,
             user
           ) do
      membership = %{membership | user: user}

      {:noreply,
       socket
       |> put_flash(:info, "Workspace member added")
       |> assign(:member_form, to_form(%{"email" => ""}, as: :member))
       |> stream_insert(:members, membership)}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Workspace member could not be added")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Workspace member could not be added")}
    end
  end

  def handle_event("change_member_role", %{"id" => id, "role" => role}, socket) do
    with %WorkspaceMembership{} = membership <-
           Organizations.get_workspace_member(socket.assigns.current_scope, id),
         {:ok, updated_membership} <-
           Organizations.change_workspace_member_role(
             socket.assigns.current_scope,
             membership,
             role
           ) do
      updated_membership = %{updated_membership | user: membership.user}
      {:noreply, stream_insert(socket, :members, updated_membership)}
    else
      _error -> {:noreply, put_flash(socket, :error, "Member role could not be changed")}
    end
  end

  def handle_event("remove_member", %{"id" => id}, socket) do
    with %WorkspaceMembership{} = membership <-
           Organizations.get_workspace_member(socket.assigns.current_scope, id),
         {:ok, _membership} <-
           Organizations.remove_workspace_member(socket.assigns.current_scope, membership) do
      {:noreply, stream_delete(socket, :members, membership)}
    else
      _error -> {:noreply, put_flash(socket, :error, "Workspace member could not be removed")}
    end
  end

  def handle_event("update_settings", %{"workspace" => %{"visibility" => visibility}}, socket) do
    case Organizations.change_workspace_visibility(
           socket.assigns.current_scope,
           socket.assigns.current_scope.workspace,
           visibility
         ) do
      {:ok, workspace} ->
        scope = %{socket.assigns.current_scope | workspace: workspace}

        {:noreply,
         socket
         |> assign(:current_scope, scope)
         |> assign(
           :settings_form,
           to_form(%{"visibility" => workspace.visibility}, as: :workspace)
         )
         |> put_flash(:info, "Workspace settings updated")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Workspace settings could not be updated")}
    end
  end

  @impl true
  def render(%{live_action: :members} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-8">
        <.workspace_header scope={@current_scope} active={:members} />

        <section
          :if={@workspace_owner? && !@current_scope.workspace.is_default}
          id="add-workspace-member"
          class="rounded-lg border border-base-300 bg-base-100 p-5 shadow-sm"
        >
          <.form for={@member_form} id="workspace-member-form" phx-submit="add_member">
            <.input field={@member_form[:email]} type="email" label="Member email" required />
            <.button variant="primary" phx-disable-with="Adding...">Add member</.button>
          </.form>
        </section>

        <div id="workspace-members" phx-update="stream" class="space-y-3">
          <article
            :for={{id, membership} <- @streams.members}
            id={id}
            class="flex flex-col gap-3 rounded-lg border border-base-300 bg-base-100 p-4 sm:flex-row sm:items-center sm:justify-between"
          >
            <div>
              <p class="font-medium">{membership.user.email}</p>
              <p class="text-sm text-base-content/60">{String.capitalize(membership.role)}</p>
            </div>
            <div
              :if={
                @workspace_owner? && !@current_scope.workspace.is_default &&
                  membership.user_id != @current_scope.user.id
              }
              class="flex gap-2"
            >
              <button
                id={"toggle-workspace-role-#{membership.id}"}
                type="button"
                phx-click="change_member_role"
                phx-value-id={membership.id}
                phx-value-role={if(membership.role == "owner", do: "member", else: "owner")}
                class="btn btn-sm btn-ghost"
              >
                {if(membership.role == "owner", do: "Make member", else: "Make owner")}
              </button>
              <button
                id={"remove-workspace-member-#{membership.id}"}
                type="button"
                phx-click="remove_member"
                phx-value-id={membership.id}
                data-confirm="Remove this workspace member?"
                class="btn btn-sm btn-error"
              >
                Remove
              </button>
            </div>
          </article>
        </div>
      </div>
    </Layouts.app>
    """
  end

  def render(%{live_action: :settings} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-8">
        <.workspace_header scope={@current_scope} active={:settings} />

        <section
          id="workspace-settings"
          class="rounded-lg border border-base-300 bg-base-100 p-5 shadow-sm"
        >
          <dl class="mb-6 grid gap-4 sm:grid-cols-2">
            <div>
              <dt class="text-sm text-base-content/60">Name</dt>
              <dd class="font-medium">{@current_scope.workspace.name}</dd>
            </div>
            <div>
              <dt class="text-sm text-base-content/60">Slug</dt>
              <dd class="font-mono text-sm">{@current_scope.workspace.slug}</dd>
            </div>
          </dl>

          <.form
            :if={@workspace_owner? && !@current_scope.workspace.is_default}
            for={@settings_form}
            id="workspace-settings-form"
            phx-submit="update_settings"
          >
            <.input
              field={@settings_form[:visibility]}
              type="select"
              label="Visibility"
              options={[{"Open", "open"}, {"Private", "private"}]}
            />
            <.button variant="primary" phx-disable-with="Saving...">Save settings</.button>
          </.form>

          <p
            :if={!@workspace_owner? || @current_scope.workspace.is_default}
            id="workspace-settings-readonly"
            class="text-sm text-base-content/60"
          >
            Visibility: {String.capitalize(@current_scope.workspace.visibility)}
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :scope, :map, required: true
  attr :active, :atom, required: true

  defp workspace_header(assigns) do
    ~H"""
    <header class="space-y-4">
      <div>
        <p class="text-sm text-base-content/60">{@scope.organization.name}</p>
        <h1 class="text-3xl font-semibold tracking-tight">{@scope.workspace.name}</h1>
      </div>
      <nav id="workspace-page-navigation" class="flex flex-wrap gap-2" aria-label="Workspace">
        <.link navigate={workspace_path(@scope, "pastes")} class="btn btn-sm btn-ghost">Pastes</.link>
        <.link
          navigate={workspace_path(@scope, "members")}
          class={["btn btn-sm", if(@active == :members, do: "btn-primary", else: "btn-ghost")]}
        >
          Members
        </.link>
        <.link
          navigate={workspace_path(@scope, "settings")}
          class={["btn btn-sm", if(@active == :settings, do: "btn-primary", else: "btn-ghost")]}
        >
          Settings
        </.link>
      </nav>
    </header>
    """
  end

  defp resolve_workspace_scope!(scope, organization_slug, workspace_slug) do
    case Organizations.resolve_workspace_scope_by_slugs(scope, organization_slug, workspace_slug) do
      {:ok, resolved_scope} -> resolved_scope
      {:error, :not_found} -> raise Ecto.NoResultsError, queryable: Workspace
    end
  end

  defp workspace_path(scope, page),
    do: "/w/#{scope.organization.slug}/#{scope.workspace.slug}/#{page}"
end
