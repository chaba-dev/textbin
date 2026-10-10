defmodule TextbinWeb.Layouts do
  @moduledoc """
  Layouts and the application shell.

  The shell has exactly one navigation surface per breakpoint, never a header
  plus a sidebar:

    * desktop (lg and up): a full sidebar
    * tablet (md to lg): a 64px rail of initials that opens the same sidebar
      as an overlay drawer, so it never pushes content
    * phone (below md): a bottom bar whose More button opens that drawer

  Pages outside an organization (log in, shared links seen by outsiders)
  render a minimal public frame instead.
  """
  use TextbinWeb, :html

  alias Textbin.Accounts.User
  alias Textbin.Organizations.{Organization, OrganizationMembership}

  embed_templates "layouts/*"

  @doc """
  Renders the app layout.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :navigation_scope, :map,
    default: nil,
    doc: "scope that draws the shell when the page itself is outside a workspace"

  attr :navigation_workspaces, :list,
    default: [],
    doc: "workspaces available in the active organization"

  attr :active_navigation, :any,
    default: nil,
    doc: "the active destination, such as {:workspace, :pastes} or {:organization, :members}"

  attr :default_appearance, :boolean,
    default: false,
    doc: "shared links use Harbor without changing the viewer's authentication"

  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :shell_scope, assigns.navigation_scope || assigns.current_scope)

    ~H"""
    <div
      id="appearance-policy"
      hidden
      phx-hook="Appearance"
      data-theme={html_theme(if @default_appearance, do: nil, else: @current_scope)}
      data-mode={html_mode(if @default_appearance, do: nil, else: @current_scope)}
    >
    </div>
    <%= if application_shell?(@shell_scope) do %>
      <div id="application-shell" class="flex h-dvh flex-col bg-base-200/45 md:flex-row">
        <div
          id="navigation-dialog-controller"
          phx-hook="NavigationDialog"
          phx-update="ignore"
          data-dialog-id="navigation-drawer"
        >
        </div>

        <dialog
          id="navigation-drawer"
          class="fixed inset-y-0 left-0 right-auto m-0 h-dvh max-h-dvh w-72 max-w-[calc(100vw-3rem)] overflow-hidden border-r border-base-300 bg-base-100 p-0 text-base-content shadow-2xl backdrop:bg-neutral/45 backdrop:backdrop-blur-[2px] lg:hidden"
          aria-label="Navigation"
        >
          <div class="flex h-full min-h-0 flex-col px-4 pb-4 pt-3">
            <div class="mb-1 flex justify-end">
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
              id="navigation-drawer-scroll-region"
              class="min-h-0 flex-1 overflow-x-hidden overflow-y-auto overscroll-contain"
            >
              <.application_sidebar
                id="drawer-navigation"
                scope={@shell_scope}
                workspaces={@navigation_workspaces}
                active={@active_navigation}
              />
            </div>
          </div>
        </dialog>

        <.navigation_rail
          scope={@shell_scope}
          workspaces={@navigation_workspaces}
          active={@active_navigation}
        />

        <aside
          id="application-sidebar"
          class="hidden h-dvh w-64 shrink-0 flex-col border-r border-base-300 bg-base-100 px-3 py-5 lg:flex"
        >
          <.application_sidebar
            id="sidebar-navigation"
            scope={@shell_scope}
            workspaces={@navigation_workspaces}
            active={@active_navigation}
          />
        </aside>

        <main
          id="main-content"
          tabindex="-1"
          class="min-h-0 min-w-0 flex-1 overflow-y-auto overscroll-contain px-4 py-6 sm:px-6 md:py-8 lg:px-10 lg:py-10"
        >
          <div class="mx-auto max-w-6xl space-y-4">
            {render_slot(@inner_block)}
          </div>
        </main>

        <.mobile_bottom_navigation
          scope={@shell_scope}
          workspaces={@navigation_workspaces}
          active={@active_navigation}
        />
      </div>
    <% else %>
      <div id="public-shell" class="min-h-dvh">
        <div class="mx-auto flex max-w-7xl items-center justify-between gap-4 px-4 py-4 sm:px-6 lg:px-8">
          <.link href={~p"/"} id="brand-home" class="rounded-lg" aria-label="textbin home">
            <.lockup />
          </.link>
          <div id="public-navigation" class="flex items-center gap-2">
            <%= if signed_in?(@current_scope) do %>
              <.link href={~p"/"} class="btn btn-ghost btn-sm">Open textbin</.link>
            <% else %>
              <.link href={~p"/users/log-in"} class="btn btn-ghost btn-sm">Log in</.link>
              <.link href={~p"/users/register"} class="btn btn-primary btn-sm">Register</.link>
            <% end %>
          </div>
        </div>
        <main id="main-content" tabindex="-1" class="px-4 pb-20 pt-8 sm:px-6 lg:px-8">
          <div class="mx-auto max-w-7xl space-y-4">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    <% end %>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  The bracket mark: a pair of square brackets around two lines of text.
  Drawn with `currentColor` so it follows the surrounding text color.
  """
  attr :class, :string, default: "size-6"

  def mark(assigns) do
    ~H"""
    <svg
      class={@class}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="2.75"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <path d="M8.5 4H4v16h4.5M15.5 4H20v16h-4.5M9.5 9.5h5M9.5 14.5h3" />
    </svg>
    """
  end

  @doc """
  The mark beside the lowercase wordmark. The gap is one bracket width.
  """
  attr :class, :string, default: nil

  def lockup(assigns) do
    ~H"""
    <span class={["inline-flex items-center gap-2 text-base-content", @class]}>
      <.mark class="size-6 text-primary" />
      <span class="text-lg font-semibold leading-none tracking-[-0.025em]">textbin</span>
    </span>
    """
  end

  @doc """
  Tabs for a workspace's own pages.
  """
  attr :scope, :map, required: true
  attr :active, :atom, required: true

  def workspace_tabs(assigns) do
    ~H"""
    <nav
      id="workspace-tabs"
      aria-label="Workspace"
      class="flex gap-1 overflow-x-auto border-b border-base-300"
    >
      <.tab
        id="workspace-tab-pastes"
        navigate={workspace_path(@scope.organization, @scope.workspace, "pastes")}
        label="Pastes"
        active={@active == :pastes}
      />
      <.tab
        id="workspace-tab-deleted"
        navigate={workspace_path(@scope.organization, @scope.workspace, "deleted")}
        label="Deleted"
        active={@active == :deleted}
      />
      <.tab
        id="workspace-tab-settings"
        navigate={workspace_path(@scope.organization, @scope.workspace, "settings")}
        label="Settings"
        active={@active == :settings}
      />
    </nav>
    """
  end

  @doc """
  Tabs for the organization pages gathered under Manage.
  """
  attr :scope, :map, required: true
  attr :active, :atom, required: true

  def manage_tabs(assigns) do
    ~H"""
    <nav
      id="manage-navigation"
      aria-label="Manage"
      class="flex gap-1 overflow-x-auto border-b border-base-300"
    >
      <.tab
        id="manage-tab-members"
        navigate={organization_members_path(@scope.organization)}
        label="Members"
        active={@active == :members}
      />
      <.tab
        id="manage-tab-workspaces"
        navigate={organization_workspaces_path(@scope.organization)}
        label="Workspaces"
        active={@active == :workspaces}
      />
      <.tab
        :if={organization_owner?(@scope)}
        id="manage-tab-audit-log"
        navigate={organization_audit_log_path(@scope.organization)}
        label="Audit log"
        active={@active == :audit_log}
      />
      <.tab
        id="manage-tab-settings"
        navigate={organization_settings_path(@scope.organization)}
        label="Organization settings"
        active={@active == :settings}
      />
    </nav>
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp tab(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "-mb-px shrink-0 border-b-2 px-3 py-2 text-sm font-medium transition",
        if(@active,
          do: "border-primary text-base-content",
          else: "border-transparent text-base-content/60 hover:text-base-content"
        )
      ]}
    >
      {@label}
    </.link>
    """
  end

  attr :scope, :map, required: true
  attr :workspaces, :list, required: true
  attr :active, :any, default: nil

  defp navigation_rail(assigns) do
    ~H"""
    <nav
      id="application-rail"
      aria-label="Application rail"
      class="hidden h-dvh w-16 shrink-0 flex-col items-center gap-2 border-r border-base-300 bg-base-100 py-4 md:flex lg:hidden"
    >
      <button
        id="rail-open-navigation"
        type="button"
        class="flex size-10 items-center justify-center rounded-xl text-primary transition hover:bg-base-200"
        aria-label="Open navigation"
        aria-controls="navigation-drawer"
        aria-expanded="false"
        data-navigation-dialog-open
      >
        <.mark class="size-6" />
      </button>

      <.link
        :if={new_paste_path(@scope, @workspaces)}
        id="rail-new-paste"
        navigate={new_paste_path(@scope, @workspaces)}
        class="btn btn-primary btn-square btn-sm"
        aria-label="New paste"
        title="New paste"
      >
        <.icon name="hero-plus" class="size-4" />
      </.link>

      <.link
        id="rail-search"
        navigate={~p"/search"}
        aria-label="Search"
        title="Search"
        aria-current={@active == :search && "page"}
        class={[
          "flex size-10 items-center justify-center rounded-xl transition",
          if(@active == :search,
            do: "bg-primary/12 text-primary",
            else: "text-base-content/60 hover:bg-base-200 hover:text-base-content"
          )
        ]}
      >
        <.icon name="hero-magnifying-glass" class="size-5" />
      </.link>

      <div class="my-1 h-px w-8 bg-base-300"></div>

      <div
        id="rail-workspaces"
        class="flex min-h-0 w-full flex-1 flex-col items-center gap-1.5 overflow-y-auto"
      >
        <.link
          :for={workspace <- @workspaces}
          navigate={workspace_path(@scope.organization, workspace, "pastes")}
          title={workspace.name}
          aria-label={workspace.name}
          aria-current={workspace_active?(@scope, workspace, @active) && "page"}
          class={[
            "flex size-10 shrink-0 items-center justify-center rounded-xl text-xs font-semibold transition",
            if(workspace_active?(@scope, workspace, @active),
              do: "bg-primary/12 text-primary",
              else: "bg-base-200 text-base-content/70 hover:bg-base-300 hover:text-base-content"
            )
          ]}
        >
          {initials(workspace.name)}
        </.link>
      </div>

      <.link
        id="rail-manage"
        navigate={organization_members_path(@scope.organization)}
        aria-label="Manage"
        title="Manage"
        aria-current={manage_active?(@active) && "page"}
        class={[
          "flex size-10 items-center justify-center rounded-xl transition",
          if(manage_active?(@active),
            do: "bg-primary/12 text-primary",
            else: "text-base-content/60 hover:bg-base-200 hover:text-base-content"
          )
        ]}
      >
        <.icon name="hero-adjustments-horizontal" class="size-5" />
      </.link>

      <button
        id="rail-account"
        type="button"
        class="flex size-9 items-center justify-center rounded-full bg-base-300 text-xs font-semibold text-base-content transition hover:ring-2 hover:ring-primary/30"
        aria-label={"Account: #{account_label(@scope)}"}
        aria-controls="navigation-drawer"
        aria-expanded="false"
        data-navigation-dialog-open
      >
        {initials(account_label(@scope))}
      </button>
    </nav>
    """
  end

  attr :scope, :map, required: true
  attr :workspaces, :list, required: true
  attr :active, :any, default: nil

  defp mobile_bottom_navigation(assigns) do
    ~H"""
    <nav
      id="mobile-bottom-navigation"
      aria-label="Mobile primary"
      class="z-20 grid w-full shrink-0 grid-cols-4 gap-1 border-t border-base-300 bg-base-100 px-3 pb-[max(0.5rem,env(safe-area-inset-bottom))] pt-1.5 md:hidden"
    >
      <.mobile_navigation_link
        :if={pastes_path(@scope, @workspaces)}
        id="mobile-pastes-link"
        navigate={pastes_path(@scope, @workspaces)}
        icon="hero-document-text"
        label="Pastes"
        active={@active == {:workspace, :pastes}}
      />
      <.mobile_navigation_link
        :if={new_paste_path(@scope, @workspaces)}
        id="mobile-new-paste-link"
        navigate={new_paste_path(@scope, @workspaces)}
        icon="hero-plus-circle"
        label="New"
        active={@active == {:workspace, :new}}
      />
      <.mobile_navigation_link
        id="mobile-search-link"
        navigate={~p"/search"}
        icon="hero-magnifying-glass"
        label="Search"
        active={@active == :search}
      />

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
        aria-controls="navigation-drawer"
        aria-expanded="false"
        data-navigation-dialog-open
      >
        <.icon name="hero-bars-3" class="size-5" />
        <span>More</span>
      </button>
    </nav>
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp mobile_navigation_link(assigns) do
    ~H"""
    <.link
      id={@id}
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

  attr :id, :string, required: true
  attr :scope, :map, required: true
  attr :workspaces, :list, required: true
  attr :active, :any, default: nil

  defp application_sidebar(assigns) do
    ~H"""
    <nav id={@id} class="flex h-full min-h-0 flex-col gap-4" aria-label="Application">
      <.link
        id={"#{@id}-home"}
        navigate={pastes_path(@scope, @workspaces) || ~p"/orgs"}
        class="flex w-fit items-center rounded-lg px-2 py-1"
        aria-label="textbin home"
      >
        <.lockup />
      </.link>

      <details id={organization_menu_id(@id)} class="group relative" data-dropdown>
        <summary class="flex cursor-pointer list-none items-center gap-3 rounded-xl border border-base-300 p-2 transition hover:bg-base-200">
          <span class="flex size-8 shrink-0 items-center justify-center rounded-lg bg-primary/12 text-xs font-semibold text-primary">
            {initials(@scope.organization.name)}
          </span>
          <span class="min-w-0 flex-1">
            <span class="block truncate text-sm font-semibold text-base-content">
              {@scope.organization.name}
            </span>
            <span class="block truncate text-xs capitalize text-base-content/50">
              {@scope.organization_membership.role}
            </span>
          </span>
          <.icon
            name="hero-chevron-up-down"
            class="size-4 shrink-0 text-base-content/40"
          />
        </summary>
        <div
          id={organization_menu_panel_id(@id)}
          class="absolute left-0 right-0 z-20 mt-2 max-h-[min(20rem,calc(100dvh-8rem))] overflow-y-auto overscroll-contain rounded-xl border border-base-300 bg-base-100 p-2 shadow-xl"
        >
          <.menu_link
            navigate={organization_path(@scope.organization)}
            icon="hero-squares-2x2"
            label="Organization overview"
            active={@active == {:organization, :overview}}
          />
          <.menu_link navigate={~p"/orgs"} icon="hero-arrows-right-left" label="Switch organization" />
          <.menu_link navigate={~p"/orgs/new"} icon="hero-plus" label="New organization" />
        </div>
      </details>

      <.link
        :if={new_paste_path(@scope, @workspaces)}
        id={"#{@id}-new-paste"}
        navigate={new_paste_path(@scope, @workspaces)}
        class="btn btn-primary btn-sm w-full justify-start"
      >
        <.icon name="hero-plus" class="size-4" /> New paste
      </.link>

      <.link
        id={"#{@id}-search"}
        navigate={~p"/search"}
        aria-current={@active == :search && "page"}
        class={[
          "flex items-center gap-2.5 rounded-lg border px-2.5 py-1.5 text-sm transition",
          if(@active == :search,
            do: "border-primary/40 bg-primary/5 text-primary",
            else:
              "border-base-300 text-base-content/55 hover:border-base-content/25 hover:text-base-content"
          )
        ]}
      >
        <.icon name="hero-magnifying-glass" class="size-4 shrink-0" />
        <span>Search</span>
      </.link>

      <div class="flex min-h-0 flex-1 flex-col">
        <div class="mb-1.5 flex items-center justify-between gap-3 px-2">
          <p class="text-[0.6875rem] font-bold uppercase tracking-[0.16em] text-base-content/40">
            Workspaces
          </p>
          <span class="rounded-full bg-base-200 px-2 py-0.5 text-[0.6875rem] font-semibold text-base-content/50">
            {length(@workspaces)}
          </span>
        </div>
        <div
          id={"#{@id}-workspaces"}
          class="min-h-0 flex-1 space-y-0.5 overflow-y-auto overscroll-contain"
        >
          <p :if={@workspaces == []} class="px-2 py-3 text-sm leading-5 text-base-content/50">
            No joined workspaces.
          </p>
          <.link
            :for={workspace <- @workspaces}
            navigate={workspace_path(@scope.organization, workspace, "pastes")}
            aria-current={workspace_active?(@scope, workspace, @active) && "page"}
            class={[
              "group flex items-center gap-2.5 rounded-lg px-2 py-1.5 text-sm transition",
              if(workspace_active?(@scope, workspace, @active),
                do: "bg-primary/10 font-semibold text-primary",
                else: "text-base-content/70 hover:bg-base-200 hover:text-base-content"
              )
            ]}
          >
            <span class={[
              "flex size-6 shrink-0 items-center justify-center rounded-md text-[0.625rem] font-semibold",
              if(workspace_active?(@scope, workspace, @active),
                do: "bg-primary/15 text-primary",
                else: "bg-base-200 text-base-content/60"
              )
            ]}>
              {initials(workspace.name)}
            </span>
            <span class="min-w-0 flex-1 truncate">{workspace.name}</span>
            <.icon :if={workspace.is_default} name="hero-star" class="size-3.5 opacity-55" />
          </.link>
        </div>
      </div>

      <div class="space-y-1 border-t border-base-300 pt-3">
        <.link
          id={"#{@id}-manage"}
          navigate={organization_members_path(@scope.organization)}
          aria-current={manage_active?(@active) && "page"}
          class={[
            "flex items-center gap-3 rounded-lg px-2.5 py-2 text-sm font-medium transition",
            if(manage_active?(@active),
              do: "bg-primary/10 text-primary",
              else: "text-base-content/65 hover:bg-base-200 hover:text-base-content"
            )
          ]}
        >
          <.icon name="hero-adjustments-horizontal" class="size-4.5 shrink-0" /> Manage
        </.link>

        <.account_menu id={"#{@id}-account-menu"} scope={@scope} active={@active} />
      </div>
    </nav>
    """
  end

  attr :id, :string, required: true
  attr :scope, :map, required: true
  attr :active, :any, default: nil

  defp account_menu(assigns) do
    ~H"""
    <details id={@id} class="group relative" data-dropdown>
      <summary
        class={[
          "flex cursor-pointer list-none items-center gap-3 rounded-lg p-2 transition hover:bg-base-200",
          @active == :account && "bg-primary/10"
        ]}
        aria-label={"Open account menu for #{account_label(@scope)}"}
      >
        <span class="flex size-7 shrink-0 items-center justify-center rounded-full bg-base-300 text-[0.625rem] font-semibold text-base-content">
          {initials(account_label(@scope))}
        </span>
        <span class="min-w-0 flex-1 truncate text-sm text-base-content/80">
          {account_label(@scope)}
        </span>
        <.icon name="hero-chevron-up" class="size-4 shrink-0 text-base-content/40" />
      </summary>
      <div class="absolute bottom-full left-0 right-0 z-20 mb-2 rounded-xl border border-base-300 bg-base-100 p-2 shadow-xl">
        <.menu_link
          href={~p"/users/settings"}
          icon="hero-user-circle"
          label="Account settings"
          active={@active == :account}
        />
        <.menu_link
          href={~p"/users/settings#appearance"}
          icon="hero-swatch"
          label="Appearance"
        />
        <.menu_link
          :if={platform_admin?(@scope)}
          navigate={~p"/admin"}
          icon="hero-shield-check"
          label="Administration"
        />
        <.link
          href={~p"/users/log-out"}
          method="delete"
          class="flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium text-error transition hover:bg-error/10"
        >
          <.icon name="hero-arrow-right-start-on-rectangle" class="size-4" /> Log out
        </.link>
      </div>
    </details>
    """
  end

  attr :navigate, :string, default: nil
  attr :href, :string, default: nil
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp menu_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      href={@href}
      aria-current={@active && "page"}
      class={[
        "flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition",
        if(@active,
          do: "bg-primary/10 font-medium text-primary",
          else: "text-base-content/70 hover:bg-base-200 hover:text-base-content"
        )
      ]}
    >
      <.icon name={@icon} class="size-4 shrink-0" /> {@label}
    </.link>
    """
  end

  defp account_label(%{user: %User{email: email}}), do: email
  defp account_label(_scope), do: ""

  defp signed_in?(%{user: %User{}}), do: true
  defp signed_in?(_scope), do: false

  defp platform_admin?(%{user: %{platform_role: "admin", suspended_at: nil}}), do: true
  defp platform_admin?(_scope), do: false

  defp application_shell?(%{
         user: %User{},
         organization: %Organization{},
         organization_membership: %OrganizationMembership{}
       }),
       do: true

  defp application_shell?(_scope), do: false

  # A workspace is highlighted only while one of its own pages is open, not
  # while Manage or account pages carry it as the navigation context.
  defp workspace_active?(%{workspace: %{id: id}}, %{id: id}, {:workspace, _page}), do: true
  defp workspace_active?(_scope, _workspace, _active), do: false

  defp manage_active?({:organization, page}), do: page != :overview
  defp manage_active?(_active), do: false

  defp more_navigation_active?(active),
    do: manage_active?(active) or active in [:account, {:workspace, :settings}]

  defp organization_owner?(%{organization_membership: %{role: "owner"}}), do: true
  defp organization_owner?(_scope), do: false

  # The workspace New paste and Pastes point at: the open one, or the first
  # joined workspace (the default sorts first) on organization pages.
  defp context_workspace(%{workspace: %{} = workspace}, _workspaces), do: workspace
  defp context_workspace(_scope, [workspace | _rest]), do: workspace
  defp context_workspace(_scope, []), do: nil

  defp pastes_path(scope, workspaces) do
    case context_workspace(scope, workspaces) do
      nil -> nil
      workspace -> workspace_path(scope.organization, workspace, "pastes")
    end
  end

  defp new_paste_path(scope, workspaces) do
    case context_workspace(scope, workspaces) do
      nil -> nil
      workspace -> workspace_path(scope.organization, workspace, "pastes/new")
    end
  end

  @doc false
  def initials(name) when is_binary(name) do
    name
    |> String.split(~r/[\s@._-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
    |> case do
      "" -> "?"
      initials -> initials
    end
  end

  def initials(_name), do: "?"

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
  The theme on `<html data-theme>`. A nil appearance scope renders no attribute:
  Harbor following the system color scheme. Shared-link presentation supplies
  nil here without changing the scope used for authentication and authorization.
  """
  def html_theme(%{user: %User{theme: theme}}), do: theme
  def html_theme(_scope), do: nil

  @doc "The color mode on `<html data-mode>`: auto, light or dark."
  def html_mode(%{user: %User{color_mode: mode}}), do: mode
  def html_mode(_scope), do: nil
end
