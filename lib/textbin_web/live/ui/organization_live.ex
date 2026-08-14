defmodule TextbinWeb.UI.OrganizationLive do
  use TextbinWeb, :live_view

  alias Textbin.Organizations
  alias Textbin.Organizations.Organization

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"organization_slug" => organization_slug}, _uri, socket) do
    scope = resolve_organization_scope!(socket.assigns.current_scope, organization_slug)
    workspaces = Organizations.list_joined_workspaces(scope, scope.organization)

    {:noreply,
     socket
     |> assign(:current_scope, scope)
     |> assign(:page_title, scope.organization.name)
     |> stream(:workspaces, workspaces, reset: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="organization-overview" class="space-y-8">
        <header class="flex flex-col gap-5 sm:flex-row sm:items-end sm:justify-between">
          <div class="flex items-start gap-4">
            <div class="flex size-12 shrink-0 items-center justify-center rounded-xl bg-primary/10 text-primary">
              <.icon name="hero-building-office-2" class="size-6" />
            </div>
            <div>
              <p class="text-sm font-medium uppercase tracking-wide text-base-content/55">
                {organization_kind_label(@current_scope.organization)}
              </p>
              <h1
                id="organization-heading"
                class="mt-1 text-3xl font-semibold tracking-tight text-base-content"
              >
                {@current_scope.organization.name}
              </h1>
              <p class="mt-2 font-mono text-sm text-base-content/55">
                /o/{@current_scope.organization.slug}
              </p>
            </div>
          </div>
          <span class="badge badge-outline capitalize">
            {@current_scope.organization_membership.role}
          </span>
        </header>

        <section class="rounded-xl border border-base-300 bg-base-100 shadow-sm">
          <div class="border-b border-base-300 px-5 py-4 sm:px-6">
            <h2 class="text-lg font-semibold text-base-content">Workspaces</h2>
            <p class="mt-1 text-sm text-base-content/60">
              Workspaces in this organization that you have joined.
            </p>
          </div>

          <div
            id="organization-workspaces"
            phx-update="stream"
            class="grid gap-3 p-4 sm:grid-cols-2 sm:p-5 lg:grid-cols-3"
          >
            <div
              id="organization-workspaces-empty"
              class="hidden min-h-40 rounded-lg border border-dashed border-base-300 p-8 text-center text-sm text-base-content/60 only:flex only:items-center only:justify-center sm:col-span-2 lg:col-span-3"
            >
              You have not joined any workspaces in this organization.
            </div>

            <.link
              :for={{id, workspace} <- @streams.workspaces}
              id={id}
              navigate={workspace_path(@current_scope.organization, workspace)}
              class="group rounded-lg border border-base-300 bg-base-100 p-4 transition duration-200 hover:-translate-y-0.5 hover:border-primary/30 hover:shadow-md"
            >
              <div class="flex items-start justify-between gap-4">
                <div class="min-w-0">
                  <div class="flex flex-wrap items-center gap-2">
                    <h3 class="truncate font-semibold text-base-content">{workspace.name}</h3>
                    <span :if={workspace.is_default} class="badge badge-sm badge-primary">
                      Default
                    </span>
                  </div>
                  <p class="mt-1 truncate font-mono text-xs text-base-content/50">
                    /{workspace.slug}
                  </p>
                </div>
                <.icon
                  name="hero-arrow-right"
                  class="mt-0.5 size-4 shrink-0 text-base-content/35 transition group-hover:translate-x-0.5 group-hover:text-primary"
                />
              </div>
              <div class="mt-5 flex items-center gap-2 text-xs text-base-content/60">
                <.icon
                  name={
                    if(workspace.visibility == "private",
                      do: "hero-lock-closed",
                      else: "hero-globe-alt"
                    )
                  }
                  class="size-4"
                />
                <span>{String.capitalize(workspace.visibility)}</span>
              </div>
            </.link>
          </div>
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

  defp organization_kind_label(%Organization{kind: "personal"}), do: "Personal organization"
  defp organization_kind_label(_organization), do: "Organization"

  defp workspace_path(organization, workspace),
    do: "/w/#{organization.slug}/#{workspace.slug}/pastes"
end
