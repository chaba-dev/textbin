defmodule TextbinWeb.Navigation do
  @moduledoc """
  Navigation context for account-level pages that sit outside any workspace,
  such as account settings and the organization list.

  The shell needs an organization and workspace to draw the sidebar. These
  pages borrow the home workspace for that purpose only, through a separate
  `:navigation_scope` assign, so `current_scope` keeps meaning exactly what
  the page is authorized for.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Textbin.Organizations

  def assign_home_navigation(socket) do
    case Organizations.resolve_home_scope(socket.assigns.current_scope) do
      {:ok, scope} ->
        socket
        |> assign(:navigation_scope, scope)
        |> assign(
          :navigation_workspaces,
          Organizations.list_joined_workspaces(scope, scope.organization)
        )

      {:error, :not_found} ->
        socket
        |> assign(:navigation_scope, nil)
        |> assign(:navigation_workspaces, [])
    end
  end
end
