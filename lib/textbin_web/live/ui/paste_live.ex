defmodule TextbinWeb.UI.PasteLive do
  use TextbinWeb, :live_view

  alias Textbin.Pastes

  def mount(_params, _session, socket) do
    {:ok, stream(socket, :pastes, Pastes.list_pastes())}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-8">
        <div class="flex flex-col gap-2">
          <p class="text-sm font-medium uppercase tracking-wide text-base-content/60">
            Textbin
          </p>
          <div class="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
            <div>
              <h1 class="text-3xl font-semibold tracking-tight text-base-content">
                Pastes
              </h1>
              <p class="mt-2 text-sm leading-6 text-base-content/70">
                Recently created snippets.
              </p>
            </div>
            <.link navigate={~p"/"} class="btn btn-sm btn-ghost">
              Home
            </.link>
          </div>
        </div>

        <div id="pastes-list" phx-update="stream" class="space-y-3">
          <div
            id="pastes-empty"
            class="hidden rounded-lg border border-dashed border-base-300 p-8 text-center text-sm text-base-content/60 only:block"
          >
            No pastes yet.
          </div>

          <article
            :for={{id, paste} <- @streams.pastes}
            id={id}
            class="rounded-lg border border-base-300 bg-base-100 p-4 shadow-sm transition hover:border-base-content/20 hover:shadow-md"
          >
            <div class="flex items-center justify-between gap-4">
              <p class="font-mono text-xs text-base-content/60">{paste.id}</p>
              <time
                class="text-xs text-base-content/50"
                datetime={DateTime.to_iso8601(paste.inserted_at)}
              >
                {Calendar.strftime(paste.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}
              </time>
            </div>

            <pre class="mt-3 overflow-x-auto whitespace-pre-wrap break-words rounded bg-base-200 p-3 text-sm leading-6"><code>{paste.data}</code></pre>
          </article>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
