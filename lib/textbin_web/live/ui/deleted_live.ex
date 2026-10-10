defmodule TextbinWeb.UI.DeletedLive do
  @moduledoc """
  The workspace's Deleted tab: removed and expired pastes that can still be
  restored before the recovery window ends.
  """
  use TextbinWeb, :live_view

  alias Textbin.Accounts
  alias Textbin.Organizations
  alias Textbin.Organizations.{Policy, Workspace}
  alias Textbin.Pastes
  alias Textbin.Pastes.Paste
  alias TextbinWeb.UI.Removal

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(
        %{"organization_slug" => organization_slug, "workspace_slug" => workspace_slug},
        _uri,
        socket
      ) do
    scope =
      case Organizations.resolve_workspace_scope_by_slugs(
             socket.assigns.current_scope,
             organization_slug,
             workspace_slug
           ) do
        {:ok, scope} -> scope
        {:error, :not_found} -> raise Ecto.NoResultsError, queryable: Workspace
      end

    :ok = Accounts.remember_last_workspace(scope.user, scope.workspace.id)

    {:noreply,
     socket
     |> assign(:current_scope, scope)
     |> assign(:page_title, "Deleted · #{scope.workspace.name}")
     |> assign(
       :navigation_workspaces,
       Organizations.list_joined_workspaces(scope, scope.organization)
     )
     |> stream(:pastes, Pastes.list_removed_pastes(scope), reset: true)}
  end

  @impl true
  def handle_event("restore", %{"id" => id}, socket) do
    case Pastes.restore_paste(socket.assigns.current_scope, id) do
      {:ok, paste} ->
        {:noreply,
         socket
         |> put_flash(:info, "Restored “#{Paste.display_title(paste)}”")
         |> stream_delete(:pastes, paste)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That paste can no longer be restored")}
    end
  end

  def handle_event("delete_now", %{"id" => id}, socket) do
    case Pastes.purge_paste(socket.assigns.current_scope, id) do
      {:ok, paste} ->
        {:noreply,
         socket
         |> put_flash(:info, "Paste permanently deleted")
         |> stream_delete(:pastes, paste)}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Paste could not be permanently deleted")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      navigation_workspaces={@navigation_workspaces}
      active_navigation={{:workspace, :deleted}}
    >
      <div class="space-y-6">
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
          <Layouts.workspace_tabs scope={@current_scope} active={:deleted} />
          <p id="recovery-window-note" class="text-sm text-base-content/60">
            Deleted and expired pastes stay here for {@current_scope.workspace.recovery_window_days} days, then they are gone for good. Their links stop working as soon as they are removed.
          </p>
        </header>

        <div id="deleted-pastes" phx-update="stream" class="space-y-3">
          <div
            id="deleted-pastes-empty"
            class="hidden min-h-48 flex-col rounded-lg border border-dashed border-base-300 p-10 text-center only:flex only:items-center only:justify-center"
          >
            <.icon name="hero-archive-box" class="size-8 text-base-content/35" />
            <p class="mt-3 text-base font-medium text-base-content/70">Nothing deleted</p>
            <p class="mt-1 text-sm text-base-content/50">
              Removed pastes show up here until the recovery window ends.
            </p>
          </div>

          <article
            :for={{id, paste} <- @streams.pastes}
            id={id}
            class="flex flex-col gap-3 rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm sm:flex-row sm:items-center sm:justify-between"
          >
            <div class="min-w-0">
              <p
                id={"deleted-paste-title-#{paste.id}"}
                class="truncate text-sm font-medium text-base-content"
              >
                {Paste.display_title(paste)}
              </p>
              <p class="mt-0.5 flex flex-wrap gap-x-3 text-xs text-base-content/55">
                <span id={"deleted-paste-reason-#{paste.id}"}>
                  {Removal.reason_sentence(paste, @current_scope)}
                </span>
                <span id={"deleted-paste-days-left-#{paste.id}"} class="text-warning">
                  {Removal.days_left_sentence(paste, @current_scope.workspace)}
                </span>
              </p>
            </div>
            <div :if={manageable?(@current_scope, paste)} class="flex shrink-0 gap-2">
              <button
                id={"restore-paste-#{paste.id}"}
                type="button"
                phx-click="restore"
                phx-value-id={paste.id}
                class="btn btn-sm btn-primary"
              >
                <.icon name="hero-arrow-uturn-left" class="size-4" /> Restore
              </button>
              <button
                id={"delete-now-#{paste.id}"}
                type="button"
                phx-click="delete_now"
                phx-value-id={paste.id}
                data-confirm="Permanently delete this paste? This cannot be undone."
                class="btn btn-sm btn-ghost text-error hover:bg-error/10"
              >
                Delete now
              </button>
            </div>
          </article>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp manageable?(scope, paste) do
    Policy.workspace_owner?(scope.workspace_membership) or
      paste.created_by_user_id == scope.user.id
  end
end
