defmodule TextbinWeb.UI.AdminLive do
  use TextbinWeb, :live_view

  on_mount {TextbinWeb.UserAuth, :require_platform_admin}

  alias Textbin.Administration

  @page_size 10

  embed_templates "admin_live/*"

  @impl true
  def render(assigns), do: index(assigns)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Platform administration")
     |> assign(:lookup_form, to_form(%{"query" => ""}, as: :lookup))
     |> assign(:moderation_form, to_form(%{"paste_id" => "", "reason" => ""}, as: :moderation))
     |> assign(:account_action_form, to_form(%{"reason" => ""}, as: :account_action))
     |> assign(:lookup_performed?, false)
     |> assign(:lookup, empty_lookup())
     |> stream_configure(:largest_pastes, dom_id: &"largest-paste-row-#{&1.row_key}")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope

    with {:ok, overview} <- Administration.get_installation_overview(scope),
         {:ok, recent_page} <-
           Administration.list_recent_public_pastes(scope,
             limit: @page_size,
             page: params["recent_page"]
           ),
         {:ok, largest_page} <-
           Administration.list_largest_pastes(scope,
             limit: @page_size,
             page: params["largest_page"]
           ),
         {:ok, audit_page} <-
           Administration.list_platform_audit_events(scope,
             limit: @page_size
           ) do
      {:noreply,
       socket
       |> assign(:overview, overview)
       |> assign(:recent_page, recent_page)
       |> assign(:largest_page, largest_page)
       |> assign(:audit_next_cursor, audit_page.next_cursor)
       |> stream(:recent_pastes, recent_page.entries, reset: true)
       |> stream(:largest_pastes, largest_stream_entries(largest_page), reset: true)
       |> stream(:platform_audit_events, audit_page.entries, reset: true)}
    else
      {:error, :forbidden} -> {:noreply, leave_admin(socket)}
    end
  end

  @impl true
  def handle_event("lookup", %{"lookup" => %{"query" => query}}, socket) do
    case Administration.lookup(socket.assigns.current_scope, query) do
      {:ok, lookup} ->
        {:noreply,
         socket
         |> assign(:lookup_form, to_form(%{"query" => String.trim(query)}, as: :lookup))
         |> assign(:lookup_performed?, true)
         |> assign(:lookup, lookup)}

      {:error, :forbidden} ->
        {:noreply, leave_admin(socket)}
    end
  end

  def handle_event(
        "moderate_paste",
        %{"moderation" => %{"paste_id" => paste_id, "reason" => reason}},
        socket
      ) do
    socket.assigns.current_scope
    |> Administration.delete_paste(paste_id, reason)
    |> handle_mutation_result(socket, "Paste removed and queued for storage cleanup.")
  end

  def handle_event(
        "account_action",
        %{
          "account_action" => %{
            "action" => action,
            "target_id" => target_id,
            "reason" => reason
          }
        },
        socket
      ) do
    result = account_action(action, socket.assigns.current_scope, target_id, reason)
    handle_mutation_result(result, socket, account_action_message(action))
  end

  def handle_event("load_more_audit", _params, %{assigns: %{audit_next_cursor: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("load_more_audit", _params, socket) do
    case Administration.list_platform_audit_events(socket.assigns.current_scope,
           limit: @page_size,
           cursor: socket.assigns.audit_next_cursor
         ) do
      {:ok, page} ->
        {:noreply,
         socket
         |> assign(:audit_next_cursor, page.next_cursor)
         |> stream(:platform_audit_events, page.entries)}

      {:error, :forbidden} ->
        {:noreply, leave_admin(socket)}

      {:error, :not_found} ->
        {:noreply, assign(socket, :audit_next_cursor, nil)}
    end
  end

  defp leave_admin(socket) do
    socket
    |> put_flash(:error, "Your platform administration access has changed.")
    |> push_navigate(to: ~p"/")
  end

  defp account_action("grant", scope, target_id, reason),
    do: Administration.grant_platform_admin(scope, target_id, reason)

  defp account_action("revoke", scope, target_id, reason),
    do: Administration.revoke_platform_admin(scope, target_id, reason)

  defp account_action("suspend", scope, target_id, reason),
    do: Administration.suspend_user(scope, target_id, reason)

  defp account_action("restore", scope, target_id, reason),
    do: Administration.restore_user(scope, target_id, reason)

  defp account_action(_action, _scope, _target_id, _reason), do: {:error, :not_found}

  defp account_action_message("grant"), do: "Platform administrator access granted."
  defp account_action_message("revoke"), do: "Platform administrator access revoked."
  defp account_action_message("suspend"), do: "Account suspended and active sessions revoked."
  defp account_action_message("restore"), do: "Account restored. A new login is still required."
  defp account_action_message(_action), do: "Account updated."

  defp handle_mutation_result({:ok, _result}, socket, message) do
    {:noreply,
     socket
     |> put_flash(:info, message)
     |> push_patch(to: ~p"/admin")}
  end

  defp handle_mutation_result({:error, :forbidden}, socket, _message),
    do: {:noreply, leave_admin(socket)}

  defp handle_mutation_result({:error, :reauthentication_required}, socket, _message) do
    {:noreply,
     socket
     |> put_flash(:error, "Reauthenticate before performing this sensitive action.")
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp handle_mutation_result({:error, reason}, socket, _message) do
    {:noreply, put_flash(socket, :error, mutation_error(reason))}
  end

  defp mutation_error(:reason_required), do: "A reason is required."
  defp mutation_error(:reason_too_long), do: "The reason must be at most 500 bytes."
  defp mutation_error(:not_found), do: "The target is unavailable or has already been handled."

  defp mutation_error(:final_active_admin),
    do: "The final active administrator cannot be removed."

  defp mutation_error(:self_suspension), do: "You cannot suspend your own account."
  defp mutation_error(:already_suspended), do: "That account is already suspended."
  defp mutation_error(:unconfirmed), do: "Only confirmed accounts can become administrators."
  defp mutation_error(:suspended), do: "A suspended account cannot become an administrator."
  defp mutation_error(:ineligible), do: "That account is not eligible for this action."
  defp mutation_error(_reason), do: "The administrative action could not be completed."

  defp empty_lookup, do: %{user: nil, organization: nil, workspace: nil}

  defp largest_stream_entries(page) do
    page.entries
    |> Enum.with_index()
    |> Enum.map(fn {paste, index} -> Map.put(paste, :row_key, "#{page.page}-#{index}") end)
  end

  def format_bytes(nil), do: "0 B"

  def format_bytes(bytes) when bytes < 1_024, do: "#{bytes} B"

  def format_bytes(bytes) when bytes < 1_048_576,
    do: "#{Float.round(bytes / 1_024, 1)} KiB"

  def format_bytes(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MiB"

  def format_timestamp(nil), do: "Never"

  def format_timestamp(timestamp),
    do: Calendar.strftime(timestamp, "%Y-%m-%d %H:%M UTC")

  def account_status(%{suspended_at: %DateTime{}}), do: "Suspended"
  def account_status(%{kind: "guest"}), do: "Guest"
  def account_status(%{confirmed_at: nil}), do: "Unconfirmed"
  def account_status(_user), do: "Active"

  def status_class("Suspended"), do: "bg-error/10 text-error"
  def status_class("Active"), do: "bg-success/10 text-success"
  def status_class(_status), do: "bg-warning/10 text-warning"

  def account_action_options(%{suspended_at: %DateTime{}}), do: [{"Restore account", "restore"}]

  def account_action_options(%{platform_role: "admin"}),
    do: [{"Revoke platform administrator", "revoke"}, {"Suspend account", "suspend"}]

  def account_action_options(_user),
    do: [{"Grant platform administrator", "grant"}, {"Suspend account", "suspend"}]

  def audit_title("platform.admin.bootstrap"), do: "Platform administrator bootstrapped"
  def audit_title("platform.admin.granted"), do: "Platform administrator granted"
  def audit_title("platform.admin.revoked"), do: "Platform administrator revoked"
  def audit_title("platform.account.suspended"), do: "Account suspended"
  def audit_title("platform.account.restored"), do: "Account restored"
  def audit_title("platform.admin.account_deleted"), do: "Administrator account deleted"
  def audit_title("platform.paste.deleted"), do: "Paste administratively removed"
  def audit_title(action), do: action

  def page_params(kind, page, assigns) do
    %{
      recent_page: if(kind == :recent, do: page, else: assigns.recent_page.page),
      largest_page: if(kind == :largest, do: page, else: assigns.largest_page.page)
    }
  end

  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :icon, :string, required: true

  def metric_card(assigns) do
    ~H"""
    <article class="group rounded-2xl border border-base-300 bg-base-100 p-4 shadow-sm transition duration-200 hover:-translate-y-0.5 hover:border-primary/30 hover:shadow-md">
      <div class="flex size-9 items-center justify-center rounded-xl bg-base-200 text-base-content/55 transition group-hover:bg-primary/10 group-hover:text-primary">
        <.icon name={@icon} class="size-4.5" />
      </div>
      <p class="mt-4 text-2xl font-semibold tracking-tight text-base-content">{@value}</p>
      <p class="mt-1 text-xs font-medium text-base-content/50">{@label}</p>
    </article>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  def summary_stat(assigns) do
    ~H"""
    <div class="min-w-0">
      <dt class="truncate text-xs text-base-content/45">{@label}</dt>
      <dd class="mt-1 truncate font-semibold capitalize text-base-content">{@value}</dd>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :description, :string, required: true
  attr :icon, :string, required: true
  attr :stream, :any, required: true
  attr :page, :map, required: true
  attr :kind, :atom, required: true
  attr :assigns, :map, required: true

  def paste_panel(assigns) do
    ~H"""
    <section id={@id} class="overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-sm">
      <div class="flex items-start gap-3 border-b border-base-300 bg-base-200/35 px-5 py-5">
        <div class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-primary/10 text-primary">
          <.icon name={@icon} class="size-5" />
        </div>
        <div>
          <h2 class="font-semibold text-base-content">{@title}</h2>
          <p class="mt-1 text-sm leading-5 text-base-content/55">{@description}</p>
        </div>
      </div>
      <div id={"#{@id}-entries"} phx-update="stream" class="divide-y divide-base-300">
        <div
          id={"#{@id}-empty"}
          class="hidden p-10 text-center text-sm text-base-content/50 only:block"
        >
          No paste metadata is available.
        </div>
        <article
          :for={{dom_id, paste} <- @stream}
          id={dom_id}
          class="flex items-start justify-between gap-4 px-5 py-4"
        >
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <span class="rounded-full bg-base-200 px-2 py-0.5 text-xs font-semibold capitalize text-base-content/65">
                {paste.audience}
              </span>
              <span class="text-xs text-base-content/45">{paste.content_type}</span>
            </div>
            <p class="mt-2 truncate text-sm font-medium text-base-content">
              {paste.organization_name} / {paste.workspace_name}
            </p>
            <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-base-content/45">
              <time datetime={DateTime.to_iso8601(paste.inserted_at)}>
                {format_timestamp(paste.inserted_at)}
              </time>
              <span :if={paste.expires_at}>Expires {format_timestamp(paste.expires_at)}</span>
            </div>
          </div>
          <div class="shrink-0 text-right">
            <p class="font-mono text-sm font-semibold text-base-content">
              {format_bytes(paste.size_bytes)}
            </p>
            <.link
              :if={paste.id}
              navigate={~p"/pastes/#{paste.id}"}
              class="mt-2 inline-flex items-center gap-1 text-xs font-semibold text-primary hover:underline"
            >
              Open <.icon name="hero-arrow-up-right" class="size-3" />
            </.link>
            <span :if={!paste.id} class="mt-2 block text-xs text-base-content/35">ID protected</span>
          </div>
        </article>
      </div>
      <.pagination
        id={"#{@id}-pagination"}
        page={@page}
        kind={@kind}
        assigns={@assigns}
      />
    </section>
    """
  end

  attr :id, :string, required: true
  attr :page, :map, required: true
  attr :kind, :atom, required: true
  attr :assigns, :map, required: true

  def pagination(assigns) do
    ~H"""
    <nav
      :if={@page.previous_page || @page.next_page}
      id={@id}
      class="flex items-center justify-between border-t border-base-300 px-5 py-3"
      aria-label="Pagination"
    >
      <.link
        :if={@page.previous_page}
        patch={~p"/admin?#{page_params(@kind, @page.previous_page, @assigns)}"}
        class="btn btn-ghost btn-sm"
      >
        <.icon name="hero-chevron-left" class="size-4" /> Previous
      </.link>
      <span :if={!@page.previous_page}></span>
      <span class="text-xs font-medium text-base-content/45">Page {@page.page}</span>
      <.link
        :if={@page.next_page}
        patch={~p"/admin?#{page_params(@kind, @page.next_page, @assigns)}"}
        class="btn btn-ghost btn-sm"
      >
        Next <.icon name="hero-chevron-right" class="size-4" />
      </.link>
      <span :if={!@page.next_page}></span>
    </nav>
    """
  end
end
