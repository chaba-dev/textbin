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
      <div
        id="application-shell"
        class="flex h-[calc(100dvh-4rem)] flex-col overflow-hidden bg-base-200/45 lg:h-auto lg:min-h-[calc(100vh-4rem)] lg:flex-row lg:overflow-visible"
      >
        <div
          id="navigation-dialog-controller"
          phx-hook="NavigationDialog"
          phx-update="ignore"
          data-dialog-id="mobile-navigation-dialog"
        >
        </div>

        <dialog
          id="mobile-navigation-dialog"
          class="fixed inset-x-3 bottom-[calc(4.75rem+env(safe-area-inset-bottom))] top-auto m-0 h-auto max-h-[calc(100dvh-6rem)] w-auto max-w-none overflow-hidden rounded-2xl border border-base-300 bg-base-100 p-0 text-base-content shadow-2xl backdrop:bg-neutral/45 backdrop:backdrop-blur-[2px] lg:hidden"
          aria-labelledby="mobile-navigation-title"
        >
          <div class="flex max-h-[calc(100dvh-6rem)] min-h-0 flex-col p-4">
            <div class="mb-3 flex items-center justify-between gap-3">
              <p id="mobile-navigation-title" class="text-sm font-semibold text-base-content">
                More
              </p>
              <button
                type="button"
                class="btn btn-square btn-ghost btn-sm"
                aria-label="Close navigation"
                data-navigation-dialog-close
                autofocus
              >
                <.icon name="hero-x-mark" class="size-5" />
              </button>
            </div>
            <div
              id="mobile-navigation-scroll-region"
              class="min-h-0 flex-1 overflow-x-hidden overflow-y-auto overscroll-contain"
            >
              <.mobile_more_navigation
                scope={@current_scope}
                workspaces={@navigation_workspaces}
                active={@active_navigation}
              />
            </div>
          </div>
        </dialog>

        <aside
          id="application-sidebar"
          class="sticky top-16 hidden h-[calc(100vh-4rem)] w-72 shrink-0 flex-col border-r border-base-300 bg-base-100 p-5 lg:flex"
        >
          <div class="min-h-0 flex-1 overflow-visible">
            <.application_sidebar
              id="sidebar-navigation"
              scope={@current_scope}
              workspaces={@navigation_workspaces}
              active={@active_navigation}
            />
          </div>
        </aside>

        <main
          id="main-content"
          tabindex="-1"
          class="min-h-0 min-w-0 flex-1 scroll-mt-20 overflow-y-auto overscroll-contain px-4 py-8 sm:px-6 lg:overflow-visible lg:px-10 lg:py-10"
        >
          <div class="mx-auto max-w-6xl space-y-4">
            {render_slot(@inner_block)}
          </div>
        </main>

        <.mobile_bottom_navigation scope={@current_scope} active={@active_navigation} />
      </div>
    <% else %>
      <main id="main-content" tabindex="-1" class="scroll-mt-20 px-4 py-20 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-7xl space-y-4">
          {render_slot(@inner_block)}
        </div>
      </main>
    <% end %>

    <.flash_group flash={@flash} />
    """
  end

  attr :scope, :map, required: true
  attr :active, :any, default: nil

  defp mobile_bottom_navigation(assigns) do
    ~H"""
    <nav
      id="mobile-bottom-navigation"
      aria-label="Mobile primary"
      class="z-20 grid w-full shrink-0 grid-cols-4 gap-1 border-t border-base-300 bg-base-100 px-3 pb-[max(0.5rem,env(safe-area-inset-bottom))] pt-1.5 lg:hidden"
    >
      <%= if @scope.workspace do %>
        <.mobile_navigation_link
          navigate={workspace_path(@scope.organization, @scope.workspace, "pastes")}
          icon="hero-document-text"
          label="Pastes"
          active={@active == {:workspace, :pastes}}
        />
        <.mobile_navigation_link
          navigate={workspace_path(@scope.organization, @scope.workspace, "members")}
          icon="hero-user-group"
          label="Members"
          active={@active == {:workspace, :members}}
        />
        <.mobile_navigation_link
          navigate={workspace_path(@scope.organization, @scope.workspace, "settings")}
          icon="hero-cog-6-tooth"
          label="Settings"
          active={@active == {:workspace, :settings}}
        />
      <% else %>
        <.mobile_navigation_link
          navigate={organization_path(@scope.organization)}
          icon="hero-squares-2x2"
          label="Overview"
          active={@active == {:organization, :overview}}
        />
        <.mobile_navigation_link
          navigate={organization_members_path(@scope.organization)}
          icon="hero-user-group"
          label="Members"
          active={@active == {:organization, :members}}
        />
        <.mobile_navigation_link
          navigate={organization_settings_path(@scope.organization)}
          icon="hero-cog-6-tooth"
          label="Settings"
          active={@active == {:organization, :settings}}
        />
      <% end %>

      <button
        type="button"
        id="mobile-navigation-more"
        class={[
          "flex min-h-14 min-w-0 flex-col items-center justify-center gap-1 rounded-xl px-1 py-2 text-[0.6875rem] font-semibold transition aria-expanded:bg-primary/10 aria-expanded:text-primary",
          if(more_navigation_active?(@active),
            do: "bg-primary/10 text-primary",
            else: "text-base-content/60 hover:bg-base-200 hover:text-base-content"
          )
        ]}
        aria-label="Open more navigation"
        aria-current={more_navigation_active?(@active) && "page"}
        aria-controls="mobile-navigation-dialog"
        aria-expanded="false"
        data-navigation-dialog-open
      >
        <.icon name="hero-ellipsis-horizontal-circle" class="size-5" />
        <span>More</span>
      </button>
    </nav>
    """
  end

  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp mobile_navigation_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "flex min-h-14 min-w-0 flex-col items-center justify-center gap-1 rounded-xl px-1 py-2 text-[0.6875rem] font-semibold transition",
        if(@active,
          do: "bg-primary/10 text-primary",
          else: "text-base-content/60 hover:bg-base-200 hover:text-base-content"
        )
      ]}
    >
      <.icon name={@icon} class="size-5" />
      <span class="max-w-full truncate">{@label}</span>
    </.link>
    """
  end

  attr :scope, :map, required: true
  attr :workspaces, :list, required: true
  attr :active, :any, default: nil

  defp mobile_more_navigation(assigns) do
    ~H"""
    <nav id="mobile-more-navigation" class="space-y-4" aria-label="More navigation">
      <section aria-labelledby="mobile-workspaces-heading">
        <div class="mb-2 flex items-center justify-between gap-3 px-2">
          <p
            id="mobile-workspaces-heading"
            class="text-[0.6875rem] font-bold uppercase tracking-[0.16em] text-base-content/45"
          >
            Workspaces
          </p>
          <span class="rounded-full bg-base-200 px-2 py-0.5 text-[0.6875rem] font-semibold text-base-content/50">
            {length(@workspaces)}
          </span>
        </div>
        <div class="space-y-1">
          <p :if={@workspaces == []} class="px-2 py-2 text-sm text-base-content/55">
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
                else: "border-base-content/25 bg-base-100"
              )
            ]}>
            </span>
            <span class="min-w-0 flex-1 truncate">{workspace.name}</span>
            <.icon :if={workspace.is_default} name="hero-star" class="size-3.5 opacity-55" />
          </.link>
        </div>
      </section>

      <div class="space-y-1 border-t border-base-300 pt-3">
        <.link
          navigate={organization_path(@scope.organization)}
          class="flex items-center gap-3 rounded-lg px-2.5 py-2 text-sm font-medium text-base-content/65 transition hover:bg-base-200 hover:text-base-content"
        >
          <.icon name="hero-building-office-2" class="size-4.5" /> Organization overview
        </.link>
        <.link
          navigate={organization_workspaces_path(@scope.organization)}
          class="flex items-center gap-3 rounded-lg px-2.5 py-2 text-sm font-medium text-base-content/65 transition hover:bg-base-200 hover:text-base-content"
        >
          <.icon name="hero-squares-2x2" class="size-4.5" /> Manage workspaces
        </.link>
        <.link
          :if={organization_owner?(@scope)}
          navigate={organization_audit_log_path(@scope.organization)}
          aria-current={@active == {:organization, :audit_log} && "page"}
          class={[
            "flex items-center gap-3 rounded-lg px-2.5 py-2 text-sm font-medium transition",
            if(@active == {:organization, :audit_log},
              do: "bg-primary/10 text-primary",
              else: "text-base-content/65 hover:bg-base-200 hover:text-base-content"
            )
          ]}
        >
          <.icon name="hero-shield-check" class="size-4.5" /> Audit log
        </.link>
        <.link
          navigate={~p"/orgs"}
          class="flex items-center gap-3 rounded-lg px-2.5 py-2 text-sm font-medium text-base-content/65 transition hover:bg-base-200 hover:text-base-content"
        >
          <.icon name="hero-arrows-right-left" class="size-4.5" /> Switch organization
        </.link>
      </div>

      <section
        id="mobile-account-navigation"
        class="border-t border-base-300 pt-4"
        aria-labelledby="mobile-account-heading"
      >
        <div class="flex items-center justify-between gap-3 px-2">
          <div class="min-w-0">
            <p id="mobile-account-heading" class="text-xs font-semibold text-base-content/55">
              Account
            </p>
            <p class="mt-1 truncate text-sm font-medium text-base-content">
              {account_label(@scope)}
            </p>
          </div>
          <.theme_toggle />
        </div>
        <div class="mt-3 space-y-1">
          <.link
            href={~p"/users/settings"}
            class="flex items-center gap-3 rounded-lg px-2.5 py-2 text-sm font-medium text-base-content/65 transition hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-user-circle" class="size-4.5" /> Account settings
          </.link>
          <.link
            href={~p"/users/log-out"}
            method="delete"
            class="flex items-center gap-3 rounded-lg px-2.5 py-2 text-sm font-medium text-error transition hover:bg-error/10"
          >
            <.icon name="hero-arrow-right-start-on-rectangle" class="size-4.5" /> Log out
          </.link>
        </div>
      </section>
    </nav>
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
        <details id={organization_menu_id(@id)} class="group relative" data-dropdown>
          <summary class="flex cursor-pointer list-none items-center gap-3 rounded-xl p-2 transition hover:bg-base-200">
            <div class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-primary/12 text-primary">
              <.icon name="hero-building-office-2" class="size-5" />
            </div>
            <div class="min-w-0 flex-1">
              <p class="truncate font-semibold text-base-content">{@scope.organization.name}</p>
              <p class="mt-0.5 truncate font-mono text-xs text-base-content/45">
                /o/{@scope.organization.slug}
              </p>
            </div>
            <.icon
              name="hero-chevron-down"
              class="size-4 shrink-0 text-base-content/40 transition group-open:rotate-180"
            />
          </summary>
          <div
            id={organization_menu_panel_id(@id)}
            class="absolute left-0 right-0 z-20 mt-2 max-h-[min(20rem,calc(100dvh-8rem))] overflow-y-auto overscroll-contain rounded-xl border border-base-300 bg-base-100 p-2 shadow-xl"
          >
            <p class="px-3 py-2 text-xs font-medium capitalize text-base-content/50">
              {@scope.organization_membership.role}
            </p>
            <.sidebar_link
              navigate={organization_path(@scope.organization)}
              icon="hero-squares-2x2"
              label="Overview"
              active={@active == {:organization, :overview}}
            />
            <.sidebar_link
              navigate={organization_members_path(@scope.organization)}
              icon="hero-user-group"
              label="Manage members"
              active={@active == {:organization, :members}}
            />
            <.sidebar_link
              navigate={organization_workspaces_path(@scope.organization)}
              icon="hero-squares-2x2"
              label="Manage workspaces"
              active={@active == {:organization, :workspaces}}
            />
            <.sidebar_link
              :if={organization_owner?(@scope)}
              navigate={organization_audit_log_path(@scope.organization)}
              icon="hero-shield-check"
              label="Audit log"
              active={@active == {:organization, :audit_log}}
            />
            <.sidebar_link
              navigate={organization_settings_path(@scope.organization)}
              icon="hero-cog-6-tooth"
              label="Organization settings"
              active={@active == {:organization, :settings}}
            />
            <div class="my-1 border-t border-base-300"></div>
            <.link
              navigate={~p"/orgs"}
              class="flex items-center gap-3 rounded-lg px-3 py-2 text-sm text-base-content/70 transition hover:bg-base-200 hover:text-base-content"
            >
              <.icon name="hero-arrows-right-left" class="size-4" /> Switch organization
            </.link>
          </div>
        </details>
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
      <div class="flex min-w-0 flex-1 items-center gap-4">
        <a href="/" class="flex w-fit shrink-0 items-center">
          <span class="text-xl font-bold tracking-tight text-base-content">Textbin</span>
        </a>
        <div
          :if={application_shell?(@current_scope)}
          id="mobile-header-context"
          class="ml-auto min-w-0 max-w-[55vw] text-right lg:hidden"
        >
          <p class="truncate text-sm font-semibold text-base-content">
            {@current_scope.organization.name}
          </p>
          <p :if={@current_scope.workspace} class="truncate text-xs text-base-content/55">
            {@current_scope.workspace.name}
          </p>
        </div>
      </div>
      <div class={[
        "min-w-0 flex-none",
        application_shell?(@current_scope) && "hidden lg:block"
      ]}>
        <ul id="app-header-nav" class="flex flex-wrap items-center justify-end gap-2 px-1">
          <%= unless @current_scope do %>
            <li>
              <.theme_toggle />
            </li>
          <% end %>
          <li>
            <%= if @current_scope do %>
              <details id="account-menu" class="relative" data-dropdown>
                <summary
                  class="btn btn-ghost w-10 cursor-pointer list-none px-0 sm:w-auto sm:max-w-56 sm:px-4"
                  aria-label={"Open account menu for #{account_label(@current_scope)}"}
                >
                  <.icon name="hero-user-circle" class="size-5 shrink-0" />
                  <span class="sr-only sm:not-sr-only sm:truncate">
                    {account_label(@current_scope)}
                  </span>
                </summary>
                <div class="absolute right-0 z-20 mt-2 max-h-[calc(100dvh-5rem)] w-[min(14rem,calc(100vw-2rem))] overflow-y-auto overscroll-contain rounded-lg border border-base-300 bg-base-100 p-2 shadow-lg">
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

  defp more_navigation_active?(active),
    do: active in [{:organization, :workspaces}, {:organization, :audit_log}]

  defp organization_owner?(%{organization_membership: %{role: "owner"}}), do: true
  defp organization_owner?(_scope), do: false

  defp organization_menu_id("sidebar-navigation"), do: "organization-menu"
  defp organization_menu_id(id), do: "#{id}-organization-menu"

  defp organization_menu_panel_id("sidebar-navigation"), do: "organization-menu-panel"
  defp organization_menu_panel_id(id), do: "#{id}-organization-menu-panel"

  defp organization_path(organization), do: "/o/#{organization.slug}"
  defp organization_audit_log_path(organization), do: "/o/#{organization.slug}/audit-log"
  defp organization_members_path(organization), do: "/o/#{organization.slug}/members"
  defp organization_workspaces_path(organization), do: "/o/#{organization.slug}/workspaces"
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
