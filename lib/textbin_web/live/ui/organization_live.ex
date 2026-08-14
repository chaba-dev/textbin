defmodule TextbinWeb.UI.OrganizationLive do
  use TextbinWeb, :live_view

  alias Textbin.Accounts
  alias Textbin.Organizations
  alias Textbin.Organizations.{Organization, OrganizationMembership, Policy}

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"organization_slug" => organization_slug}, _uri, socket) do
    scope = resolve_organization_scope!(socket.assigns.current_scope, organization_slug)

    socket =
      socket
      |> assign(:current_scope, scope)
      |> assign(:page_title, scope.organization.name)

    case socket.assigns.live_action do
      :show ->
        workspaces = Organizations.list_joined_workspaces(scope, scope.organization)
        {:noreply, stream(socket, :workspaces, workspaces, reset: true)}

      :members ->
        {:noreply,
         socket
         |> assign(
           :organization_manager?,
           Policy.organization_manager?(scope.organization_membership)
         )
         |> assign(:member_form, to_form(%{"email" => ""}, as: :member))
         |> stream(:members, Organizations.list_organization_members(scope), reset: true)}

      :settings ->
        {:noreply,
         socket
         |> assign(
           :organization_owner?,
           Policy.organization_owner?(scope.organization_membership)
         )
         |> assign(
           :settings_form,
           scope.organization
           |> Organization.settings_changeset(%{})
           |> to_form()
         )}
    end
  end

  @impl true
  def handle_event(
        "add_member",
        %{"member" => %{"email" => email}},
        %{assigns: %{live_action: :members}} = socket
      ) do
    with %{} = user <- Accounts.get_user_by_email(String.trim(email)),
         {:ok, memberships} <-
           Organizations.add_organization_member(
             socket.assigns.current_scope,
             socket.assigns.current_scope.organization,
             user
           ) do
      membership = %{memberships.organization | user: user}

      {:noreply,
       socket
       |> put_flash(:info, "Organization member added")
       |> assign(:member_form, to_form(%{"email" => ""}, as: :member))
       |> stream_insert(:members, membership)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "Organization member could not be added")}
    end
  end

  def handle_event(
        "change_member_role",
        %{"id" => id, "role" => role},
        %{assigns: %{live_action: :members}} = socket
      ) do
    with %OrganizationMembership{} = membership <-
           Organizations.get_organization_member(socket.assigns.current_scope, id),
         {:ok, updated_membership} <-
           Organizations.change_organization_member_role(
             socket.assigns.current_scope,
             membership,
             role
           ) do
      updated_membership = %{updated_membership | user: membership.user}
      {:noreply, stream_insert(socket, :members, updated_membership)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "Organization member role could not be changed")}
    end
  end

  def handle_event(
        "remove_member",
        %{"id" => id},
        %{assigns: %{live_action: :members}} = socket
      ) do
    with %OrganizationMembership{} = membership <-
           Organizations.get_organization_member(socket.assigns.current_scope, id),
         false <- membership.user_id == socket.assigns.current_scope.user.id,
         {:ok, _membership} <-
           Organizations.remove_organization_member(socket.assigns.current_scope, membership) do
      {:noreply, stream_delete(socket, :members, membership)}
    else
      _error ->
        {:noreply, put_flash(socket, :error, "Organization member could not be removed")}
    end
  end

  def handle_event(
        "update_settings",
        %{"organization" => organization_params},
        %{assigns: %{live_action: :settings}} = socket
      ) do
    case Organizations.change_organization_settings(
           socket.assigns.current_scope,
           socket.assigns.current_scope.organization,
           organization_params
         ) do
      {:ok, organization} ->
        scope = %{socket.assigns.current_scope | organization: organization}

        {:noreply,
         socket
         |> assign(:current_scope, scope)
         |> assign(:page_title, organization.name)
         |> assign(
           :settings_form,
           organization |> Organization.settings_changeset(%{}) |> to_form()
         )
         |> put_flash(:info, "Organization settings updated")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :settings_form, to_form(changeset, action: :update))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Organization settings could not be updated")}
    end
  end

  def handle_event("update_settings", _params, socket), do: {:noreply, socket}

  @impl true
  def render(%{live_action: :show} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="organization-overview" class="space-y-8">
        <.organization_header scope={@current_scope} active={:overview} />

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

  def render(%{live_action: :members} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="organization-members-page" class="space-y-8">
        <.organization_header scope={@current_scope} active={:members} />

        <section
          :if={@organization_manager?}
          id="add-organization-member"
          class="rounded-xl border border-base-300 bg-base-100 p-5 shadow-sm"
        >
          <div class="mb-4">
            <h2 class="font-semibold text-base-content">Add a member</h2>
            <p class="mt-1 text-sm text-base-content/60">
              New members also join the organization’s default workspace.
            </p>
          </div>
          <.form
            for={@member_form}
            id="organization-member-form"
            phx-submit="add_member"
            class="flex flex-col gap-3 sm:flex-row sm:items-end"
          >
            <.input
              field={@member_form[:email]}
              type="email"
              label="Member email"
              required
            />
            <.button variant="primary" phx-disable-with="Adding...">Add member</.button>
          </.form>
        </section>

        <section class="overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-sm">
          <div class="border-b border-base-300 px-5 py-4 sm:px-6">
            <h2 class="text-lg font-semibold text-base-content">Members</h2>
            <p class="mt-1 text-sm text-base-content/60">
              People with access to this organization.
            </p>
          </div>

          <div id="organization-members" phx-update="stream" class="divide-y divide-base-300">
            <article
              :for={{id, membership} <- @streams.members}
              id={id}
              class="flex flex-col gap-4 px-5 py-4 sm:flex-row sm:items-center sm:justify-between sm:px-6"
            >
              <div class="min-w-0">
                <p class="truncate font-medium text-base-content">{membership.user.email}</p>
                <span
                  id={"organization-member-role-#{membership.id}"}
                  class="mt-1 inline-flex text-xs font-medium capitalize text-base-content/55"
                >
                  {membership.role}
                </span>
              </div>

              <div :if={@organization_manager?} class="flex flex-wrap items-center gap-2">
                <button
                  :for={role <- available_role_changes(@current_scope, membership)}
                  id={"change-organization-role-#{membership.id}-#{role}"}
                  type="button"
                  phx-click="change_member_role"
                  phx-value-id={membership.id}
                  phx-value-role={role}
                  class="btn btn-sm btn-ghost"
                >
                  {role_action_label(role)}
                </button>
                <button
                  :if={removable_member?(@current_scope, membership)}
                  id={"remove-organization-member-#{membership.id}"}
                  type="button"
                  phx-click="remove_member"
                  phx-value-id={membership.id}
                  data-confirm="Remove this organization member and their workspace access?"
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

  def render(%{live_action: :settings} = assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div id="organization-settings-page" class="space-y-8">
        <.organization_header scope={@current_scope} active={:settings} />

        <section class="rounded-xl border border-base-300 bg-base-100 p-5 shadow-sm sm:p-6">
          <div class="mb-6">
            <h2 class="text-lg font-semibold text-base-content">General</h2>
            <p class="mt-1 text-sm text-base-content/60">
              Organization identity used throughout Textbin.
            </p>
          </div>

          <.form
            :if={@organization_owner?}
            for={@settings_form}
            id="organization-settings-form"
            phx-submit="update_settings"
            class="max-w-2xl space-y-4"
          >
            <.input field={@settings_form[:name]} type="text" label="Organization name" required />
            <div>
              <.input
                id="organization-slug"
                name="organization_slug"
                type="text"
                label="Slug"
                value={@current_scope.organization.slug}
                disabled
              />
              <p class="text-xs leading-5 text-base-content/50">
                Slug changes are not yet available because they would affect existing links.
              </p>
            </div>
            <.button variant="primary" phx-disable-with="Saving...">Save changes</.button>
          </.form>

          <dl
            :if={!@organization_owner?}
            id="organization-settings-readonly"
            class="grid gap-5 sm:grid-cols-2"
          >
            <div>
              <dt class="text-sm text-base-content/55">Name</dt>
              <dd class="mt-1 font-medium text-base-content">{@current_scope.organization.name}</dd>
            </div>
            <div>
              <dt class="text-sm text-base-content/55">Slug</dt>
              <dd class="mt-1 font-mono text-sm text-base-content">
                {@current_scope.organization.slug}
              </dd>
            </div>
          </dl>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :scope, :map, required: true
  attr :active, :atom, required: true

  defp organization_header(assigns) do
    ~H"""
    <header class="space-y-5">
      <div class="flex flex-col gap-5 sm:flex-row sm:items-end sm:justify-between">
        <div class="flex items-start gap-4">
          <div class="flex size-12 shrink-0 items-center justify-center rounded-xl bg-primary/10 text-primary">
            <.icon name="hero-building-office-2" class="size-6" />
          </div>
          <div>
            <p class="text-sm font-medium uppercase tracking-wide text-base-content/55">
              {organization_kind_label(@scope.organization)}
            </p>
            <h1
              id="organization-heading"
              class="mt-1 text-3xl font-semibold tracking-tight text-base-content"
            >
              {@scope.organization.name}
            </h1>
            <p class="mt-2 font-mono text-sm text-base-content/55">
              /o/{@scope.organization.slug}
            </p>
          </div>
        </div>
        <span class="badge badge-outline capitalize">
          {@scope.organization_membership.role}
        </span>
      </div>

      <nav id="organization-navigation" class="flex flex-wrap gap-2" aria-label="Organization">
        <.link
          navigate={organization_path(@scope.organization)}
          class={[
            "btn btn-sm",
            if(@active == :overview, do: "btn-primary", else: "btn-ghost")
          ]}
        >
          Overview
        </.link>
        <.link
          navigate={organization_members_path(@scope.organization)}
          class={[
            "btn btn-sm",
            if(@active == :members, do: "btn-primary", else: "btn-ghost")
          ]}
        >
          Members
        </.link>
        <.link
          navigate={organization_settings_path(@scope.organization)}
          class={[
            "btn btn-sm",
            if(@active == :settings, do: "btn-primary", else: "btn-ghost")
          ]}
        >
          Settings
        </.link>
      </nav>
    </header>
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

  defp available_role_changes(
         %{user: %{id: actor_id}, organization_membership: %{role: "owner"}},
         %OrganizationMembership{user_id: target_id, role: current_role}
       )
       when actor_id != target_id,
       do: ["owner", "admin", "member"] -- [current_role]

  defp available_role_changes(
         %{user: %{id: actor_id}, organization_membership: %{role: "admin"}},
         %OrganizationMembership{user_id: target_id, role: current_role}
       )
       when actor_id != target_id and current_role != "owner",
       do: ["admin", "member"] -- [current_role]

  defp available_role_changes(_scope, _membership), do: []

  defp removable_member?(scope, membership) do
    membership.user_id != scope.user.id and
      (scope.organization_membership.role == "owner" or
         (scope.organization_membership.role == "admin" and membership.role != "owner"))
  end

  defp role_action_label(role), do: "Make #{role}"

  defp organization_path(organization), do: "/o/#{organization.slug}"
  defp organization_members_path(organization), do: "/o/#{organization.slug}/members"
  defp organization_settings_path(organization), do: "/o/#{organization.slug}/settings"

  defp workspace_path(organization, workspace),
    do: "/w/#{organization.slug}/#{workspace.slug}/pastes"
end
