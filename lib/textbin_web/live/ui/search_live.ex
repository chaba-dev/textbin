defmodule TextbinWeb.UI.SearchLive do
  @moduledoc """
  Search across every workspace the person belongs to. The query lives in the
  URL so results can be shared with teammates and survive a reload.
  """
  use TextbinWeb, :live_view

  alias Textbin.Pastes
  alias Textbin.Pastes.Paste
  alias TextbinWeb.Navigation

  @impl true
  def mount(_params, _session, socket) do
    {:ok, Navigation.assign_home_navigation(socket)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = params |> Map.get("q", "") |> String.slice(0, 200)
    results = Pastes.search_pastes(socket.assigns.current_scope, query)

    {:noreply,
     socket
     |> assign(:query, query)
     |> assign(:page_title, if(query == "", do: "Search", else: "Search · #{query}"))
     |> assign(:search_form, to_form(%{"q" => query}, as: :search))
     |> assign(:result_count, length(results))
     |> stream(:results, results, reset: true, dom_id: &"search-result-#{&1.paste.id}")}
  end

  @impl true
  def handle_event("search", %{"search" => %{"q" => query}}, socket) do
    {:noreply, push_patch(socket, to: search_path(query), replace: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      navigation_scope={@navigation_scope}
      navigation_workspaces={@navigation_workspaces}
      active_navigation={:search}
    >
      <div class="space-y-6">
        <header class="space-y-4">
          <h1 id="search-heading" class="text-2xl font-semibold tracking-tight lg:text-3xl">
            Search
          </h1>
          <.form
            for={@search_form}
            id="search-form"
            phx-change="search"
            phx-submit="search"
            role="search"
          >
            <label for="search_q" class="sr-only">Search pastes</label>
            <div class="relative">
              <.icon
                name="hero-magnifying-glass"
                class="pointer-events-none absolute left-3 top-1/2 z-10 size-5 -translate-y-1/2 text-base-content/40"
              />
              <input
                id="search_q"
                type="search"
                name={@search_form[:q].name}
                value={@search_form[:q].value}
                placeholder="Search titles and content in your workspaces"
                phx-debounce="250"
                autocomplete="off"
                autofocus
                class="input input-lg w-full pl-10"
              />
            </div>
          </.form>
          <p id="search-scope-note" class="text-xs text-base-content/50">
            Searches every workspace you belong to. Deleted pastes and binary files are left out, and large pastes are matched by title.
          </p>
        </header>

        <p :if={@query != ""} id="search-summary" class="text-sm text-base-content/60">
          {result_summary(@result_count, @query)}
        </p>

        <div id="search-results" phx-update="stream" class="space-y-3">
          <div
            :if={@query != ""}
            id="search-results-empty"
            class="hidden min-h-40 flex-col rounded-lg border border-dashed border-base-300 p-10 text-center only:flex only:items-center only:justify-center"
          >
            <p class="font-medium text-base-content/70">No pastes match “{@query}”</p>
            <p class="mt-1 text-sm text-base-content/50">Try a shorter or different phrase.</p>
          </div>

          <.link
            :for={{id, result} <- @streams.results}
            id={id}
            navigate={paste_path(result)}
            class="block rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm transition hover:border-base-content/20 hover:shadow-md"
          >
            <div class="flex flex-wrap items-baseline justify-between gap-2">
              <p class="min-w-0 truncate text-sm font-medium text-base-content">
                {Paste.display_title(result.paste)}
              </p>
              <p class="text-xs text-base-content/50">
                {result.organization.name} / {result.workspace.name}
              </p>
            </div>
            <p
              :if={result.excerpt}
              id={"search-excerpt-#{result.paste.id}"}
              class="mt-2 break-words rounded-md bg-base-200 px-3 py-2 font-mono text-xs leading-5 text-base-content/70"
            >
              {elem(result.excerpt, 0)}<mark class="rounded bg-warning/30 px-0.5 text-base-content">{elem(result.excerpt, 1)}</mark>{elem(
                result.excerpt,
                2
              )}
            </p>
          </.link>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp search_path(""), do: ~p"/search"
  defp search_path(query), do: ~p"/search?#{[q: query]}"

  defp paste_path(%{organization: organization, workspace: workspace, paste: paste}),
    do: "/w/#{organization.slug}/#{workspace.slug}/pastes/#{paste.id}"

  defp result_summary(count, _query) when count >= 50, do: "Showing the 50 newest matches"
  defp result_summary(1, _query), do: "1 match"
  defp result_summary(count, _query), do: "#{count} matches"
end
