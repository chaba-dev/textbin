defmodule TextbinWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use TextbinWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :navigation_workspaces, :list,
    default: [],
    doc: "workspaces available in the active organization"

  attr :active_navigation, :any,
    default: nil,
    doc: "the active organization or workspace navigation destination"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <%= if application_shell?(@current_scope) do %>
      <div id="application-shell" class="min-h-[calc(100vh-4rem)] bg-base-200/45 lg:flex">
        <input
          id="mobile-sidebar-toggle"
          type="checkbox"
          class="peer sr-only lg:hidden"
          aria-label="Toggle navigation"
          aria-controls="application-sidebar"
        />

        <div class="flex items-center gap-3 border-b border-base-300 bg-base-100 px-4 py-3 peer-focus-visible:[&_#mobile-sidebar-open]:ring-2 peer-focus-visible:[&_#mobile-sidebar-open]:ring-primary lg:hidden">
          <label
            for="mobile-sidebar-toggle"
            id="mobile-sidebar-open"
            class="btn btn-square btn-ghost btn-sm"
            aria-label="Open navigation"
          >
            <.icon name="hero-bars-3" class="size-5" />
          </label>
          <div class="min-w-0">
            <p class="truncate text-sm font-semibold text-base-content">
              {@current_scope.organization.name}
            </p>
            <p :if={@current_scope.workspace} class="truncate text-xs text-base-content/55">
              {@current_scope.workspace.name}
            </p>
          </div>
        </div>

        <label
          for="mobile-sidebar-toggle"
          class="pointer-events-none fixed inset-0 z-40 bg-neutral/45 opacity-0 backdrop-blur-[2px] transition-opacity peer-checked:pointer-events-auto peer-checked:opacity-100 lg:hidden"
          aria-label="Close navigation"
        >
        </label>

        <aside
          id="application-sidebar"
          class="fixed inset-y-0 left-0 z-50 flex w-[min(20rem,88vw)] -translate-x-full flex-col border-r border-base-300 bg-base-100 p-4 shadow-2xl transition-transform duration-200 peer-checked:translate-x-0 lg:sticky lg:top-16 lg:z-auto lg:h-[calc(100vh-4rem)] lg:w-72 lg:shrink-0 lg:translate-x-0 lg:p-5 lg:shadow-none"
        >
          <div class="mb-3 flex justify-end lg:hidden">
            <label
              for="mobile-sidebar-toggle"
              class="btn btn-square btn-ghost btn-sm"
              aria-label="Close navigation"
            >
              <.icon name="hero-x-mark" class="size-5" />
            </label>
          </div>
          <div class="min-h-0 flex-1 overflow-hidden">
            <.application_sidebar
              id="sidebar-navigation"
              scope={@current_scope}
              workspaces={@navigation_workspaces}
              active={@active_navigation}
            />
          </div>
        </aside>

        <main id="application-content" class="min-w-0 flex-1 px-4 py-8 sm:px-6 lg:px-10 lg:py-10">
          <div class="mx-auto max-w-6xl space-y-4">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    <% else %>
      <main class="px-4 py-20 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-7xl space-y-4">
          {render_slot(@inner_block)}
        </div>
      </main>
    <% end %>

    <.flash_group flash={@flash} />
    """
  end

  attr :id, :string, required: true
  attr :scope, :map, required: true
  attr :workspaces, :list, required: true
  attr :active, :any, default: nil

  defp application_sidebar(assigns) do
    ~H"""
    <nav id={@id} class="flex h-full min-h-0 flex-col" aria-label="Application">
      <div class="border-b border-base-300 pb-5">
        <div class="flex items-start gap-3">
          <div class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-primary/12 text-primary">
            <.icon name="hero-building-office-2" class="size-5" />
          </div>
          <div class="min-w-0 flex-1">
            <.link
              navigate={organization_path(@scope.organization)}
              class="block truncate font-semibold text-base-content transition hover:text-primary"
            >
              {@scope.organization.name}
            </.link>
            <p class="mt-0.5 truncate font-mono text-xs text-base-content/45">
              /o/{@scope.organization.slug}
            </p>
          </div>
          <.link
            navigate={~p"/orgs"}
            class="btn btn-square btn-ghost btn-xs"
            title="View organizations"
            aria-label="View organizations"
          >
            <.icon name="hero-arrows-right-left" class="size-4" />
          </.link>
        </div>
        <span class="mt-3 inline-flex rounded-full bg-base-200 px-2.5 py-1 text-[0.6875rem] font-semibold uppercase tracking-wide text-base-content/55">
          {@scope.organization_membership.role}
        </span>
      </div>

      <div class="border-b border-base-300 py-5">
        <p class="mb-2 px-2 text-[0.6875rem] font-bold uppercase tracking-[0.16em] text-base-content/40">
          Organization
        </p>
        <div class="space-y-1">
          <.sidebar_link
            navigate={organization_path(@scope.organization)}
            icon="hero-squares-2x2"
            label="Overview"
            active={@active == {:organization, :overview}}
          />
          <.sidebar_link
            navigate={organization_members_path(@scope.organization)}
            icon="hero-user-group"
            label="Members"
            active={@active == {:organization, :members}}
          />
          <.sidebar_link
            navigate={organization_settings_path(@scope.organization)}
            icon="hero-adjustments-horizontal"
            label="Settings"
            active={@active == {:organization, :settings}}
          />
        </div>
      </div>

      <div class="flex min-h-0 flex-1 flex-col py-5">
        <div class="mb-2 flex items-center justify-between gap-3 px-2">
          <p class="text-[0.6875rem] font-bold uppercase tracking-[0.16em] text-base-content/40">
            Workspaces
          </p>
          <span class="rounded-full bg-base-200 px-2 py-0.5 text-[0.6875rem] font-semibold text-base-content/50">
            {length(@workspaces)}
          </span>
        </div>
        <div
          id={"#{@id}-workspaces"}
          class="min-h-0 flex-1 space-y-1 overflow-y-auto overscroll-contain pr-1"
        >
          <p :if={@workspaces == []} class="px-2 py-3 text-sm leading-5 text-base-content/50">
            No joined workspaces.
          </p>
          <.link
            :for={workspace <- @workspaces}
            navigate={workspace_path(@scope.organization, workspace, "pastes")}
            class={[
              "group flex items-center gap-3 rounded-lg px-2.5 py-2 text-sm transition",
              if(active_workspace?(@scope, workspace),
                do: "bg-primary/10 font-semibold text-primary",
                else: "text-base-content/65 hover:bg-base-200 hover:text-base-content"
              )
            ]}
          >
            <span class={[
              "size-2 rounded-full border",
              if(active_workspace?(@scope, workspace),
                do: "border-primary bg-primary",
                else: "border-base-content/25 bg-base-100 group-hover:border-base-content/45"
              )
            ]}>
            </span>
            <span class="min-w-0 flex-1 truncate">{workspace.name}</span>
            <.icon :if={workspace.is_default} name="hero-star" class="size-3.5 opacity-55" />
          </.link>
        </div>

        <div :if={@scope.workspace} class="mt-5 border-t border-base-300 pt-5">
          <p class="mb-2 truncate px-2 text-xs font-semibold text-base-content/55">
            {@scope.workspace.name}
          </p>
          <div class="space-y-1">
            <.sidebar_link
              navigate={workspace_path(@scope.organization, @scope.workspace, "pastes")}
              icon="hero-document-text"
              label="Pastes"
              active={@active == {:workspace, :pastes}}
            />
            <.sidebar_link
              navigate={workspace_path(@scope.organization, @scope.workspace, "members")}
              icon="hero-user-group"
              label="Members"
              active={@active == {:workspace, :members}}
            />
            <.sidebar_link
              navigate={workspace_path(@scope.organization, @scope.workspace, "settings")}
              icon="hero-cog-6-tooth"
              label="Settings"
              active={@active == {:workspace, :settings}}
            />
          </div>
        </div>
      </div>
    </nav>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp sidebar_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "flex items-center gap-3 rounded-lg px-2.5 py-2 text-sm font-medium transition",
        if(@active,
          do: "bg-primary/10 text-primary",
          else: "text-base-content/65 hover:bg-base-200 hover:text-base-content"
        )
      ]}
    >
      <.icon name={@icon} class="size-4.5 shrink-0" />
      <span>{@label}</span>
    </.link>
    """
  end

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  def app_header(assigns) do
    ~H"""
    <header
      id="app-header"
      class="navbar sticky top-0 z-30 h-16 min-h-16 gap-4 border-b border-base-300 bg-base-100/95 px-4 backdrop-blur sm:px-6 lg:px-8"
    >
      <div class="flex flex-1 items-center">
        <a href="/" class="flex w-fit items-center">
          <span class="text-xl font-bold tracking-tight text-base-content">Textbin</span>
        </a>
      </div>
      <div class="flex-none">
        <ul id="app-header-nav" class="flex flex-wrap items-center justify-end gap-2 px-1">
          <%= unless @current_scope do %>
            <li>
              <.theme_toggle />
            </li>
          <% end %>
          <li>
            <%= if @current_scope do %>
              <details class="relative">
                <summary class="btn btn-ghost max-w-56 cursor-pointer list-none truncate">
                  {account_label(@current_scope)}
                </summary>
                <div class="absolute right-0 z-20 mt-2 w-56 rounded-lg border border-base-300 bg-base-100 p-2 shadow-lg">
                  <div class="truncate px-3 py-2 text-xs text-base-content/60">
                    {account_label(@current_scope)}
                  </div>
                  <div class="flex items-center justify-between gap-3 px-3 py-2">
                    <span class="text-xs font-medium text-base-content/60">Theme</span>
                    <.theme_toggle />
                  </div>
                  <%= if guest_scope?(@current_scope) do %>
                    <.link href={~p"/users/log-in"} class="btn btn-ghost btn-sm w-full justify-start">
                      Log in
                    </.link>
                    <.link
                      href={~p"/users/register"}
                      class="btn btn-ghost btn-sm w-full justify-start"
                    >
                      Register
                    </.link>
                  <% else %>
                    <.link
                      href={~p"/orgs"}
                      class="btn btn-ghost btn-sm w-full justify-start"
                    >
                      Organizations
                    </.link>
                    <.link
                      href={~p"/users/settings"}
                      class="btn btn-ghost btn-sm w-full justify-start"
                    >
                      Settings
                    </.link>
                    <.link
                      href={~p"/users/log-out"}
                      method="delete"
                      class="btn btn-ghost btn-sm w-full justify-start text-error hover:bg-error/10"
                    >
                      Log out
                    </.link>
                  <% end %>
                </div>
              </details>
            <% else %>
              <.link href={~p"/users/log-in"} class="btn btn-ghost">Log in</.link>
            <% end %>
          </li>
          <%= unless @current_scope do %>
            <li>
              <.link href={~p"/users/register"} class="btn btn-primary">Register</.link>
            </li>
          <% end %>
        </ul>
      </div>
    </header>
    """
  end

  defp account_label(%{user: %Textbin.Accounts.User{} = user}) do
    if Textbin.Accounts.User.guest?(user), do: "Guest", else: user.email
  end

  defp account_label(_scope), do: "Guest"

  defp guest_scope?(%{user: %Textbin.Accounts.User{} = user}),
    do: Textbin.Accounts.User.guest?(user)

  defp guest_scope?(_scope), do: false

  defp application_shell?(%{
         user: %Textbin.Accounts.User{} = user,
         organization: %Textbin.Organizations.Organization{},
         organization_membership: %Textbin.Organizations.OrganizationMembership{}
       }),
       do: not Textbin.Accounts.User.guest?(user)

  defp application_shell?(_scope), do: false

  defp active_workspace?(%{workspace: %{id: workspace_id}}, %{id: workspace_id}), do: true
  defp active_workspace?(_scope, _workspace), do: false

  defp organization_path(organization), do: "/o/#{organization.slug}"
  defp organization_members_path(organization), do: "/o/#{organization.slug}/members"
  defp organization_settings_path(organization), do: "/o/#{organization.slug}/settings"

  defp workspace_path(organization, workspace, page),
    do: "/w/#{organization.slug}/#{workspace.slug}/#{page}"

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
