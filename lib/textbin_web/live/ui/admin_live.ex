defmodule TextbinWeb.UI.AdminLive do
  use TextbinWeb, :live_view

  on_mount {TextbinWeb.UserAuth, :require_platform_admin}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "Administration")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <main id="admin-page" class="mx-auto w-full max-w-5xl px-4 py-10 sm:px-6 lg:px-8">
        <section class="overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-sm">
          <div class="border-b border-base-300 bg-base-200/35 px-6 py-8 sm:px-8">
            <div class="flex items-start gap-4">
              <div class="flex size-11 shrink-0 items-center justify-center rounded-xl bg-primary/10 text-primary">
                <.icon name="hero-shield-check" class="size-6" />
              </div>
              <div>
                <p class="text-sm font-semibold uppercase tracking-[0.16em] text-primary">
                  Platform controls
                </p>
                <h1 class="mt-2 text-3xl font-semibold tracking-tight text-base-content">
                  Administration
                </h1>
                <p class="mt-3 max-w-2xl text-sm leading-6 text-base-content/65">
                  This restricted area is authorized against current platform authority on every
                  mount and authority change.
                </p>
              </div>
            </div>
          </div>

          <div id="admin-foundation-status" class="px-6 py-6 sm:px-8">
            <div class="flex items-center gap-3 rounded-xl border border-success/25 bg-success/5 px-4 py-3">
              <span class="flex size-8 items-center justify-center rounded-full bg-success/15 text-success">
                <.icon name="hero-lock-closed" class="size-4" />
              </span>
              <div>
                <p class="text-sm font-semibold text-base-content">Authorization boundary active</p>
                <p class="mt-0.5 text-sm text-base-content/60">
                  Operational views will be introduced in the next delivery phase.
                </p>
              </div>
            </div>
          </div>
        </section>
      </main>
    </Layouts.app>
    """
  end
end
