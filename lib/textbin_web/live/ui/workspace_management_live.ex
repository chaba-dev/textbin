defmodule TextbinWeb.UI.WorkspaceManagementLive do
  use TextbinWeb, :live_view

  alias Textbin.Organizations
  alias Textbin.Organizations.{Organization, Policy, Workspace}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"organization_slug" => organization_slug}, _uri, socket) do
    scope = resolve_organization_scope!(socket.assigns.current_scope, organization_slug)

    socket =
      socket
      |> assign(:current_scope, scope)
      |> assign(:navigation_workspaces, joined_workspaces(scope))

    case socket.assigns.live_action do
      :index ->
        {:noreply,
         socket
         |> assign(:page_title, "Workspaces · #{scope.organization.name}")
         |> assign(
           :organization_manager?,
           Policy.organization_manager?(scope.organization_membership)
         )
         |> stream_available_workspaces()}

      :new ->
        if Policy.organization_manager?(scope.organization_membership) do
          {:noreply,
           socket
           |> assign(:page_title, "Create workspace · #{scope.organization.name}")
           |> assign_workspace_form()}
        else
          {:noreply,
           socket
           |> put_flash(:error, "You do not have permission to create a workspace")
           |> push_navigate(to: organization_workspaces_path(scope.organization))}
        end
    end
  end

  @impl true
  def handle_event(
        "validate_workspace",
        %{"workspace" => workspace_params},
        %{assigns: %{live_action: :new}} = socket
      ) do
    form =
      socket
      |> new_workspace()
      |> Workspace.changeset(workspace_params)
      |> to_form(action: :validate)

    {:noreply, assign(socket, :workspace_form, form)}
  end

  def handle_event(
        "create_workspace",
        %{"workspace" => workspace_params},
        %{assigns: %{live_action: :new}} = socket
      ) do
    scope = socket.assigns.current_scope

    case Organizations.create_workspace(scope, scope.organization, workspace_params) do
      {:ok, workspace} ->
        {:noreply,
         socket
         |> put_flash(:info, "Workspace created")
         |> push_navigate(to: workspace_path(scope.organization, workspace))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :workspace_form, to_form(changeset, action: :insert))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Workspace could not be created")}
    end
  end

  def handle_event(
        "join_workspace",
        %{"id" => workspace_id},
        %{assigns: %{live_action: :index}} = socket
      ) do
    scope = socket.assigns.current_scope

    with %Workspace{} = workspace <- available_workspace(scope, workspace_id),
         {:ok, _membership} <- Organizations.join_workspace(scope, workspace) do
      {:noreply,
       socket
       |> put_flash(:info, "Workspace joined")
       |> push_navigate(to: workspace_path(scope.organization, workspace))}
    else
      _error -> {:noreply, put_flash(socket, :error, "Workspace could not be joined")}
    end
  end

  def handle_event(
        "leave_workspace",
        %{"id" => workspace_id},
        %{assigns: %{live_action: :index}} = socket
      ) do
    scope = socket.assigns.current_scope

    with %Workspace{} = workspace <- available_workspace(scope, workspace_id),
         {:ok, _membership} <- Organizations.leave_workspace(scope, workspace) do
      {:noreply,
       socket
       |> put_flash(:info, "Workspace left")
       |> assign(:navigation_workspaces, joined_workspaces(scope))
       |> stream_available_workspaces()}
    else
      _error -> {:noreply, put_flash(socket, :error, "Workspace could not be left")}
    end
  end

  def handle_event(event, _params, socket)
      when event in [
             "validate_workspace",
             "create_workspace",
             "join_workspace",
             "leave_workspace"
           ],
      do: {:noreply, socket}

  @impl true
  def render(%{live_action: :index} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      navigation_workspaces={@navigation_workspaces}
      active_navigation={{:organization, :workspaces}}
    >
      <div id="organization-workspaces-page" class="space-y-8">
        <header class="flex flex-col gap-5 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <p class="text-sm font-medium text-base-content/55">
              {@current_scope.organization.name}
            </p>
            <h1 class="mt-1 text-3xl font-semibold tracking-tight text-base-content">
              Workspaces
            </h1>
            <p class="mt-3 max-w-2xl text-sm leading-6 text-base-content/60">
              Open workspaces are available to everyone in the organization. Private workspaces
              appear only after an owner adds you.
            </p>
          </div>
          <.link
            :if={@organization_manager?}
            id="new-workspace-link"
            navigate={organization_new_workspace_path(@current_scope.organization)}
            class="btn btn-primary w-full sm:w-auto"
          >
            <.icon name="hero-plus" class="size-4" /> New workspace
          </.link>
        </header>

        <section class="overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-sm">
          <div class="border-b border-base-300 px-5 py-4 sm:px-6">
            <h2 class="font-semibold text-base-content">Available workspaces</h2>
            <p class="mt-1 text-sm text-base-content/60">
              Join open workspaces or manage the ones you already use.
            </p>
          </div>

          <div id="available-workspaces" phx-update="stream" class="divide-y divide-base-300">
            <div
              id="available-workspaces-empty"
              class="hidden p-10 text-center text-sm text-base-content/55 only:block"
            >
              No workspaces are currently available.
            </div>
            <article
              :for={{id, row} <- @streams.available_workspaces}
              id={id}
              class="flex flex-col gap-5 px-5 py-5 sm:flex-row sm:items-center sm:justify-between sm:px-6"
            >
              <div class="flex min-w-0 items-start gap-4">
                <div class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-base-200 text-base-content/55">
                  <.icon
                    name={
                      if(row.workspace.visibility == "private",
                        do: "hero-lock-closed",
                        else: "hero-globe-alt"
                      )
                    }
                    class="size-5"
                  />
                </div>
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="truncate font-semibold text-base-content">{row.workspace.name}</h3>
                    <span :if={row.workspace.is_default} class="badge badge-sm badge-primary">
                      Default
                    </span>
                    <span :if={row.joined?} class="badge badge-sm badge-ghost">Joined</span>
                  </div>
                  <p class="mt-1 truncate font-mono text-xs text-base-content/45">
                    /{row.workspace.slug}
                  </p>
                  <p class="mt-2 text-xs capitalize text-base-content/55">
                    {row.workspace.visibility} workspace
                  </p>
                </div>
              </div>

              <div class="flex shrink-0 flex-col gap-2 sm:flex-row sm:items-center">
                <.link
                  :if={row.joined?}
                  navigate={workspace_path(@current_scope.organization, row.workspace)}
                  class="btn btn-sm btn-outline"
                >
                  Open
                </.link>
                <button
                  :if={row.joined? && !row.workspace.is_default}
                  id={"leave-workspace-#{row.workspace.id}"}
                  type="button"
                  phx-click="leave_workspace"
                  phx-value-id={row.workspace.id}
                  data-confirm="Leave this workspace? You’ll need to join again or be invited to regain access."
                  class="btn btn-sm btn-ghost text-error hover:bg-error/10"
                >
                  Leave
                </button>
                <button
                  :if={!row.joined?}
                  id={"join-workspace-#{row.workspace.id}"}
                  type="button"
                  phx-click="join_workspace"
                  phx-value-id={row.workspace.id}
                  class="btn btn-sm btn-primary"
                >
                  Join workspace
                </button>
              </div>
            </article>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  def render(%{live_action: :new} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      navigation_workspaces={@navigation_workspaces}
      active_navigation={{:organization, :workspaces}}
    >
      <div id="new-workspace-page" class="mx-auto max-w-3xl">
        <.link
          id="back-to-workspaces"
          navigate={organization_workspaces_path(@current_scope.organization)}
          class="group inline-flex items-center gap-2 text-sm font-medium text-base-content/60 transition hover:text-base-content"
        >
          <.icon name="hero-arrow-left" class="size-4 transition group-hover:-translate-x-0.5" />
          Workspaces
        </.link>

        <section class="mt-6 rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm sm:p-8 lg:p-10">
          <div class="flex items-start gap-4">
            <div class="flex size-11 shrink-0 items-center justify-center rounded-xl bg-primary/12 text-primary">
              <.icon name="hero-squares-2x2" class="size-5" />
            </div>
            <div>
              <p class="text-sm font-medium text-base-content/55">
                {@current_scope.organization.name}
              </p>
              <h1 class="mt-1 text-2xl font-semibold tracking-tight text-base-content sm:text-3xl">
                Create a workspace
              </h1>
            </div>
          </div>

          <.form
            for={@workspace_form}
            id="workspace-form"
            phx-change="validate_workspace"
            phx-submit="create_workspace"
            class="mt-8 space-y-5"
          >
            <.input
              field={@workspace_form[:name]}
              type="text"
              label="Workspace name"
              placeholder="Product"
              required
            />
            <div>
              <.input
                field={@workspace_form[:slug]}
                type="text"
                label="Slug"
                placeholder="product"
                spellcheck="false"
                required
              />
              <p class="mt-1.5 text-xs leading-5 text-base-content/50">
                Use lowercase letters, numbers, and hyphens.
              </p>
            </div>
            <div>
              <.input
                field={@workspace_form[:visibility]}
                type="select"
                label="Who can find and join this workspace?"
                options={[
                  {"Everyone in the organization", "open"},
                  {"Invited members only", "private"}
                ]}
              />
              <p class="mt-1.5 text-xs leading-5 text-base-content/50">
                Private workspaces stay hidden from organization members who have not been invited.
              </p>
            </div>

            <div class="flex flex-col-reverse gap-3 pt-3 sm:flex-row sm:justify-end">
              <.link
                navigate={organization_workspaces_path(@current_scope.organization)}
                class="btn btn-ghost"
              >
                Cancel
              </.link>
              <.button variant="primary" phx-disable-with="Creating...">
                Create workspace
              </.button>
            </div>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp resolve_organization_scope!(scope, organization_slug) do
    case Organizations.resolve_organization_scope_by_slug(scope, organization_slug) do
      {:ok, resolved_scope} -> resolved_scope
      {:error, :not_found} -> raise Ecto.NoResultsError, queryable: Organization
    end
  end

  defp assign_workspace_form(socket) do
    form = socket |> new_workspace() |> Workspace.changeset(%{}) |> to_form()
    assign(socket, :workspace_form, form)
  end

  defp new_workspace(socket) do
    scope = socket.assigns.current_scope

    %Workspace{
      organization_id: scope.organization.id,
      created_by_id: scope.user.id,
      is_default: false
    }
  end

  defp stream_available_workspaces(socket) do
    scope = socket.assigns.current_scope
    joined_ids = scope |> joined_workspaces() |> MapSet.new(& &1.id)

    rows =
      scope
      |> available_workspaces()
      |> Enum.map(fn workspace ->
        %{workspace: workspace, joined?: MapSet.member?(joined_ids, workspace.id)}
      end)

    stream(socket, :available_workspaces, rows,
      reset: true,
      dom_id: fn row -> "available-workspaces-#{row.workspace.id}" end
    )
  end

  defp joined_workspaces(scope),
    do: Organizations.list_joined_workspaces(scope, scope.organization)

  defp available_workspace(scope, workspace_id) do
    Enum.find(available_workspaces(scope), &(&1.id == workspace_id))
  end

  defp available_workspaces(scope) do
    case Organizations.list_available_workspaces(scope, scope.organization) do
      {:ok, workspaces} -> workspaces
      {:error, _reason} -> []
    end
  end

  defp organization_workspaces_path(organization), do: "/o/#{organization.slug}/workspaces"

  defp organization_new_workspace_path(organization),
    do: "/o/#{organization.slug}/workspaces/new"

  defp workspace_path(organization, workspace),
    do: "/w/#{organization.slug}/#{workspace.slug}/pastes"
end
