defmodule TextbinWeb.UI.AuditLogLive do
  use TextbinWeb, :live_view

  alias Textbin.Organizations
  alias Textbin.Organizations.{AuditEvent, Organization}

  @page_size 25

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def handle_params(%{"organization_slug" => organization_slug}, _uri, socket) do
    scope = resolve_organization_scope!(socket.assigns.current_scope, organization_slug)

    socket =
      socket
      |> assign(:current_scope, scope)
      |> assign(:page_title, "Audit log · #{scope.organization.name}")
      |> assign(
        :navigation_workspaces,
        Organizations.list_joined_workspaces(scope, scope.organization)
      )

    case audit_page(scope) do
      {:ok, page} ->
        {:noreply,
         socket
         |> assign(:next_cursor, page.next_cursor)
         |> stream(:audit_events, page.events, reset: true)}

      {:error, :unauthorized} ->
        {:noreply, deny_access(socket)}

      {:error, :not_found} ->
        raise Ecto.NoResultsError, queryable: Organization
    end
  end

  @impl true
  def handle_event("load_more", _params, %{assigns: %{next_cursor: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("load_more", _params, socket) do
    scope = socket.assigns.current_scope

    case audit_page(scope, socket.assigns.next_cursor) do
      {:ok, page} ->
        {:noreply,
         socket
         |> assign(:next_cursor, page.next_cursor)
         |> stream(:audit_events, page.events)}

      {:error, :unauthorized} ->
        {:noreply, deny_access(socket)}

      {:error, :not_found} ->
        {:noreply, conceal_access(socket)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      navigation_workspaces={@navigation_workspaces}
      active_navigation={{:organization, :audit_log}}
    >
      <div id="organization-audit-log-page" class="space-y-8">
        <header>
          <p class="text-sm font-medium text-base-content/55">
            {@current_scope.organization.name}
          </p>
          <h1 class="mt-1 text-3xl font-semibold tracking-tight text-base-content">Audit log</h1>
          <p class="mt-3 max-w-2xl text-sm leading-6 text-base-content/60">
            Review security-sensitive organization, workspace, membership, and policy changes.
          </p>
        </header>

        <section class="overflow-hidden rounded-xl border border-base-300 bg-base-100 shadow-sm">
          <div class="flex items-start gap-3 border-b border-base-300 bg-base-200/35 px-5 py-4 sm:px-6">
            <div class="flex size-9 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary">
              <.icon name="hero-shield-check" class="size-5" />
            </div>
            <div>
              <h2 class="font-semibold text-base-content">Administrative activity</h2>
              <p class="mt-1 text-sm text-base-content/60">
                Events are shown newest first and retained as an immutable history.
              </p>
            </div>
          </div>

          <div id="audit-events" phx-update="stream" class="divide-y divide-base-300">
            <div
              id="audit-events-empty"
              class="hidden p-12 text-center text-sm text-base-content/55 only:block"
            >
              No administrative activity has been recorded yet.
            </div>

            <article
              :for={{id, event} <- @streams.audit_events}
              id={id}
              class="flex gap-3 px-4 py-5 sm:gap-4 sm:px-6"
            >
              <div class="flex size-10 shrink-0 items-center justify-center rounded-xl bg-base-200 text-base-content/60">
                <.icon name={event_icon(event.action)} class="size-5" />
              </div>
              <div class="min-w-0 flex-1">
                <div class="flex flex-col gap-1 sm:flex-row sm:items-start sm:justify-between sm:gap-4">
                  <h3 class="font-semibold text-base-content">{event_title(event.action)}</h3>
                  <time
                    class="shrink-0 text-xs text-base-content/45"
                    datetime={DateTime.to_iso8601(event.inserted_at)}
                  >
                    {Calendar.strftime(event.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}
                  </time>
                </div>
                <p class="mt-1 break-words text-sm leading-6 text-base-content/65">
                  {event_description(event)}
                </p>
                <div class="mt-3 flex flex-wrap items-center gap-x-4 gap-y-1 text-xs text-base-content/50">
                  <span class="inline-flex min-w-0 items-center gap-1.5">
                    <.icon name="hero-user-circle" class="size-4 shrink-0" />
                    <span class="break-all">{actor_label(event)}</span>
                  </span>
                  <span class="inline-flex min-w-0 items-center gap-1.5" title={event.target_id}>
                    <.icon name="hero-cursor-arrow-rays" class="size-4 shrink-0" />
                    <span class="break-all">{target_label(event)}</span>
                  </span>
                  <span
                    :if={workspace_label(event)}
                    class="inline-flex items-center gap-1.5"
                  >
                    <.icon name="hero-squares-2x2" class="size-4 shrink-0" />
                    <span class="break-words">{workspace_label(event)}</span>
                  </span>
                </div>
              </div>
            </article>
          </div>

          <div :if={@next_cursor} class="border-t border-base-300 p-4 text-center">
            <button
              id="load-more-audit-events"
              type="button"
              phx-click="load_more"
              phx-disable-with="Loading..."
              class="btn btn-sm btn-outline"
            >
              Load older activity
            </button>
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

  defp audit_page(scope, cursor \\ nil) do
    Organizations.list_audit_event_page(scope, scope.organization,
      limit: @page_size,
      cursor: cursor
    )
  end

  defp deny_access(socket) do
    socket
    |> put_flash(:error, "Only organization owners can view the audit log")
    |> push_navigate(to: organization_path(socket.assigns.current_scope.organization))
  end

  defp conceal_access(socket) do
    socket
    |> assign(:next_cursor, nil)
    |> stream(:audit_events, [], reset: true)
    |> put_flash(:error, "The organization could not be found")
    |> push_navigate(to: ~p"/orgs")
  end

  defp actor_label(%AuditEvent{metadata: %{"actor_email" => email}}), do: email
  defp actor_label(%AuditEvent{actor_user_id: id}), do: "User · #{short_id(id)}"

  defp target_label(%AuditEvent{metadata: %{"target_email" => email}}), do: email
  defp target_label(%AuditEvent{metadata: %{"target_name" => name}}), do: name

  defp target_label(%AuditEvent{target_type: type, target_id: id}),
    do: "#{String.capitalize(type)} · #{short_id(id)}"

  defp workspace_label(%AuditEvent{metadata: %{"workspace_name" => name}}), do: name
  defp workspace_label(_event), do: nil

  defp event_title("workspace.created"), do: "Workspace created"
  defp event_title("workspace.deleted"), do: "Workspace deleted"
  defp event_title("workspace.membership.added"), do: "Workspace member added"
  defp event_title("workspace.membership.removed"), do: "Workspace member removed"
  defp event_title("workspace.membership.role_changed"), do: "Workspace role changed"
  defp event_title("workspace.visibility_changed"), do: "Workspace visibility changed"

  defp event_title("workspace.external_sharing_policy_changed"),
    do: "External sharing policy changed"

  defp event_title("workspace.recovery_access_granted"), do: "Workspace access recovered"
  defp event_title("organization.membership.added"), do: "Organization member added"
  defp event_title("organization.membership.removed"), do: "Organization member removed"
  defp event_title("organization.membership.role_changed"), do: "Organization role changed"
  defp event_title("organization.name_changed"), do: "Organization renamed"

  defp event_title(action),
    do: action |> String.replace([".", "_"], " ") |> String.capitalize()

  defp event_description(%AuditEvent{
         action: "workspace.created",
         metadata: %{"visibility" => visibility}
       }),
       do: "Created #{visibility_article(visibility)} #{visibility} workspace."

  defp event_description(%AuditEvent{
         action: "workspace.deleted",
         metadata: %{"name" => name}
       }),
       do: "Deleted the workspace “#{name}”."

  defp event_description(%AuditEvent{
         action: "organization.name_changed",
         metadata: %{"old" => old, "new" => new}
       }),
       do: "Changed the organization name from “#{old}” to “#{new}”."

  defp event_description(%AuditEvent{
         action: action,
         metadata: %{"old_role" => old, "new_role" => new}
       })
       when action in [
              "organization.membership.role_changed",
              "workspace.membership.role_changed"
            ],
       do: "Changed the member role from #{old} to #{new}."

  defp event_description(%AuditEvent{
         action: action,
         metadata: %{"role" => role, "self" => true}
       })
       when action in ["organization.membership.removed", "workspace.membership.removed"],
       do: "A #{role} left voluntarily."

  defp event_description(
         %AuditEvent{
           action: "workspace.membership.added",
           metadata: %{"role" => role} = metadata
         } = event
       ),
       do: "Granted #{role} access to #{target_label(event)}#{workspace_description(metadata)}."

  defp event_description(
         %AuditEvent{
           action: "organization.membership.added",
           metadata: %{"role" => role}
         } = event
       ),
       do: "Granted #{role} access to #{target_label(event)}."

  defp event_description(%AuditEvent{
         action: action,
         metadata: %{"role" => role}
       })
       when action in ["organization.membership.removed", "workspace.membership.removed"],
       do: "Removed a member who had the #{role} role."

  defp event_description(%AuditEvent{
         action: "organization.membership.removed",
         metadata: %{"reason" => "account_deleted"}
       }),
       do: "Removed a member after their account was deleted."

  defp event_description(%AuditEvent{
         action: "workspace.visibility_changed",
         metadata: %{"old" => old, "new" => new}
       }),
       do: "Changed workspace visibility from #{old} to #{new}."

  defp event_description(%AuditEvent{
         action: "workspace.external_sharing_policy_changed",
         metadata: %{"old" => old, "new" => new}
       }),
       do: "Changed external sharing from #{old} to #{new}."

  defp event_description(%AuditEvent{
         action: "workspace.recovery_access_granted",
         metadata: %{"role" => role}
       }),
       do: "Recovered workspace access with the #{role} role."

  defp event_description(event),
    do: "Recorded an administrative change to this #{event.target_type}."

  defp event_icon(action) when action in ["workspace.created", "workspace.membership.added"],
    do: "hero-plus-circle"

  defp event_icon(action) when action in ["workspace.deleted", "workspace.membership.removed"],
    do: "hero-minus-circle"

  defp event_icon(action) when action in ["organization.membership.added"],
    do: "hero-user-plus"

  defp event_icon(action) when action in ["organization.membership.removed"],
    do: "hero-user-minus"

  defp event_icon(action)
       when action in [
              "organization.membership.role_changed",
              "workspace.membership.role_changed"
            ],
       do: "hero-arrows-right-left"

  defp event_icon("workspace.recovery_access_granted"), do: "hero-shield-check"
  defp event_icon(_action), do: "hero-cog-6-tooth"

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(_id), do: "unknown"

  defp visibility_article("open"), do: "an"
  defp visibility_article(_visibility), do: "a"

  defp workspace_description(%{"workspace_name" => name}), do: " in “#{name}”"
  defp workspace_description(_metadata), do: ""

  defp organization_path(organization), do: "/o/#{organization.slug}"
end
