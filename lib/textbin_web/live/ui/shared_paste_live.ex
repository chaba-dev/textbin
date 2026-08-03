defmodule TextbinWeb.UI.SharedPasteLive do
  use TextbinWeb, :live_view

  alias Textbin.Accounts.{Scope, User}
  alias Textbin.Pastes
  alias Textbin.Pastes.Paste

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Pastes.get_shared_paste(socket.assigns.current_scope, id) do
      %Paste{} = paste ->
        {:ok,
         socket
         |> assign(:page_title, "Paste #{paste.id}")
         |> assign(:paste, paste)
         |> assign(:owner?, owner?(socket.assigns.current_scope, paste))
         |> assign(:highlighted_paste_data, highlighted_paste_data(paste))}

      nil ->
        raise Ecto.NoResultsError, queryable: Paste
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <main id="shared-paste" class="space-y-6">
        <header class="flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
          <div class="min-w-0 space-y-2">
            <p class="text-sm font-medium uppercase text-base-content/60">Shared paste</p>
            <h1 class="break-all font-mono text-lg font-semibold text-base-content">
              {@paste.id}
            </h1>
            <div class="flex flex-wrap items-center gap-x-3 gap-y-2">
              <span id="shared-paste-syntax" class="badge badge-sm badge-outline">
                {@paste.syntax_highlight}
              </span>
              <span id="shared-paste-visibility" class="badge badge-sm badge-outline">
                {String.capitalize(@paste.visibility)}
              </span>
              <time
                id="shared-paste-created-at"
                class="text-sm text-base-content/60"
                datetime={DateTime.to_iso8601(@paste.inserted_at)}
              >
                Created {Calendar.strftime(@paste.inserted_at, "%Y-%m-%d %H:%M:%S UTC")}
              </time>
              <%= if @paste.expires_at do %>
                <time
                  id="shared-paste-expires-at"
                  class="text-sm text-base-content/60"
                  datetime={DateTime.to_iso8601(@paste.expires_at)}
                >
                  Expires {Calendar.strftime(@paste.expires_at, "%Y-%m-%d %H:%M:%S UTC")}
                </time>
              <% else %>
                <span id="shared-paste-expires-at" class="text-sm text-base-content/60">
                  Never expires
                </span>
              <% end %>
            </div>
          </div>

          <div class="flex shrink-0 flex-wrap items-center gap-2">
            <button
              id="copy-paste-content"
              type="button"
              phx-hook="CopyToClipboard"
              data-copy-target="#shared-paste-data code"
              class="btn btn-sm btn-primary"
              title="Copy paste content"
            >
              <.icon name="hero-clipboard" class="size-4" />
              <span data-copy-label>Copy</span>
            </button>
            <.link
              id="raw-paste-link"
              href={~p"/p/#{@paste.id}/raw"}
              target="_blank"
              class="btn btn-sm btn-ghost"
              title="View raw paste"
            >
              <.icon name="hero-code-bracket" class="size-4" /> Raw
            </.link>
            <.link
              :if={@owner?}
              id="manage-paste-link"
              navigate={~p"/pastes/#{@paste.id}"}
              class="btn btn-sm btn-ghost"
            >
              Manage
            </.link>
          </div>
        </header>

        <div
          id="shared-paste-data"
          class="overflow-x-auto rounded-lg border border-base-300 bg-base-200 text-sm leading-6"
        >
          {@highlighted_paste_data}
        </div>
      </main>
    </Layouts.app>
    """
  end

  defp owner?(%Scope{user: %User{id: user_id}}, %Paste{user_id: user_id}), do: true
  defp owner?(_current_scope, _paste), do: false

  defp highlighted_paste_data(%Paste{} = paste) do
    paste.data
    |> Lumis.highlight!(formatter: {:html_inline, language: highlight_language(paste)})
    |> then(&{:safe, &1})
  end

  defp highlight_language(%Paste{syntax_highlight: syntax_highlight})
       when is_binary(syntax_highlight) do
    case String.trim(syntax_highlight) do
      "" -> "plain"
      language -> language
    end
  end

  defp highlight_language(_paste), do: "plain"
end
