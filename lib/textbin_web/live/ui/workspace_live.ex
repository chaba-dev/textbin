defmodule TextbinWeb.UI.WorkspaceLive do
  use TextbinWeb, :live_view

  alias Textbin.Accounts
  alias Textbin.Organizations
  alias Textbin.Organizations.{Policy, Workspace, WorkspaceMembership}
  alias TextbinWeb.Sharing

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  # Members live inside Settings now; the old address keeps working.
  @impl true
  def handle_params(
        %{"organization_slug" => organization_slug, "workspace_slug" => workspace_slug},
        _uri,
        %{assigns: %{live_action: :members}} = socket
      ) do
    # Resolve first so an unreachable workspace stays concealed rather than
    # confirming its address through a redirect.
    _scope =
      resolve_workspace_scope!(socket.assigns.current_scope, organization_slug, workspace_slug)

    {:noreply,
     push_navigate(socket,
       to: "/w/#{organization_slug}/#{workspace_slug}/settings"
     )}
  end

  def handle_params(
        %{"organization_slug" => organization_slug, "workspace_slug" => workspace_slug},
        _uri,
        socket
      ) do
    scope =
      resolve_workspace_scope!(socket.assigns.current_scope, organization_slug, workspace_slug)

    :ok = Accounts.remember_last_workspace(scope.user, scope.workspace.id)

    {:noreply,
     socket
     |> assign(:current_scope, scope)
     |> assign(:page_title, scope.workspace.name)
     |> assign(
       :navigation_workspaces,
       Organizations.list_joined_workspaces(scope, scope.organization)
     )
     |> assign(:workspace_owner?, Policy.workspace_owner?(scope.workspace_membership))
     |> assign(:member_form, to_form(%{"email" => ""}, as: :member))
     |> assign(
       :settings_form,
       to_form(
         %{
           "visibility" => scope.workspace.visibility,
           "external_sharing_policy" => scope.workspace.external_sharing_policy,
           "recovery_window_days" => scope.workspace.recovery_window_days
         },
         as: :workspace
       )
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

  # Re-render on change so the sentence under each setting describes the
  # option being considered, before anything is saved.
  def handle_event("change_settings", %{"workspace" => workspace_params}, socket) do
    {:noreply, assign(socket, :settings_form, to_form(workspace_params, as: :workspace))}
  end

  def handle_event("update_settings", %{"workspace" => workspace_params}, socket) do
    case Organizations.change_workspace_settings(
           socket.assigns.current_scope,
           socket.assigns.current_scope.workspace,
           workspace_params
         ) do
      {:ok, workspace} ->
        scope = %{socket.assigns.current_scope | workspace: workspace}

        {:noreply,
         socket
         |> assign(:current_scope, scope)
         |> assign(
           :settings_form,
           to_form(
             %{
               "visibility" => workspace.visibility,
               "external_sharing_policy" => workspace.external_sharing_policy,
               "recovery_window_days" => workspace.recovery_window_days
             },
             as: :workspace
           )
         )
         |> put_flash(:info, "Workspace settings updated")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Workspace settings could not be updated")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      navigation_workspaces={@navigation_workspaces}
      active_navigation={{:workspace, :settings}}
    >
      <div class="space-y-8">
        <header class="space-y-4">
          <div>
            <p class="text-sm font-medium text-base-content/55">
              {@current_scope.organization.name}
            </p>
            <h1
              id="workspace-heading"
              class="mt-1 text-2xl font-semibold tracking-tight text-base-content lg:text-3xl"
            >
              {@current_scope.workspace.name}
            </h1>
          </div>
          <Layouts.workspace_tabs scope={@current_scope} active={:settings} />
        </header>

        <section
          id="workspace-settings"
          class="rounded-lg border border-base-300 bg-base-100 p-5 shadow-sm"
        >
          <h2 class="text-lg font-semibold text-base-content">General</h2>
          <dl class="mb-6 mt-4 grid gap-4 sm:grid-cols-2">
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
            :if={@workspace_owner?}
            for={@settings_form}
            id="workspace-settings-form"
            phx-change="change_settings"
            phx-submit="update_settings"
          >
            <div :if={!@current_scope.workspace.is_default}>
              <.input
                field={@settings_form[:visibility]}
                type="select"
                label="Who can join"
                options={Sharing.join_policy_options()}
              />
              <p id="workspace-join-policy-sentence" class="-mt-1 mb-3 text-xs text-base-content/60">
                {Sharing.join_policy_sentence(@settings_form[:visibility].value)}
              </p>
            </div>
            <.input
              field={@settings_form[:external_sharing_policy]}
              type="select"
              label="Sharing outside the team"
              options={Sharing.sharing_policy_options()}
            />
            <p id="workspace-sharing-policy-sentence" class="-mt-1 mb-3 text-xs text-base-content/60">
              {Sharing.sharing_policy_sentence(@settings_form[:external_sharing_policy].value)}
            </p>
            <.input
              field={@settings_form[:recovery_window_days]}
              type="select"
              label="Keep removed pastes for"
              options={recovery_window_options()}
            />
            <.button variant="primary" phx-disable-with="Saving...">Save settings</.button>
          </.form>

          <p
            :if={!@workspace_owner?}
            id="workspace-settings-readonly"
            class="text-sm text-base-content/60"
          >
            Who can join: {Sharing.join_policy_label(@current_scope.workspace.visibility)} · Sharing outside the team: {Sharing.sharing_policy_label(
              @current_scope.workspace.external_sharing_policy
            )} · Removed pastes kept for {@current_scope.workspace.recovery_window_days} days
          </p>
        </section>

        <section id="workspace-members-section" class="space-y-4">
          <div>
            <h2 class="text-lg font-semibold text-base-content">Members</h2>
            <p class="mt-1 text-sm text-base-content/60">
              People who can see and create pastes in this workspace.
            </p>
          </div>

          <div
            :if={@workspace_owner? && !@current_scope.workspace.is_default}
            id="add-workspace-member"
            class="rounded-lg border border-base-300 bg-base-100 p-5 shadow-sm"
          >
            <.form for={@member_form} id="workspace-member-form" phx-submit="add_member">
              <.input field={@member_form[:email]} type="email" label="Member email" required />
              <.button variant="primary" phx-disable-with="Adding...">Add member</.button>
            </.form>
          </div>

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
                :if={@workspace_owner? && membership.user_id != @current_scope.user.id}
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
                  :if={!@current_scope.workspace.is_default}
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
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp recovery_window_options do
    for days <- Workspace.recovery_windows() do
      {if(days == 1, do: "1 day", else: "#{days} days"), days}
    end
  end

  defp resolve_workspace_scope!(scope, organization_slug, workspace_slug) do
    case Organizations.resolve_workspace_scope_by_slugs(scope, organization_slug, workspace_slug) do
      {:ok, resolved_scope} -> resolved_scope
      {:error, :not_found} -> raise Ecto.NoResultsError, queryable: Workspace
    end
  end
end
