defmodule TextbinWeb.PageController do
  use TextbinWeb, :controller

  alias Textbin.Organizations

  # Home is not a page of its own: it reopens the workspace someone used last.
  def home(conn, _params) do
    case Organizations.resolve_home_scope(conn.assigns.current_scope) do
      {:ok, %{organization: organization, workspace: workspace}} ->
        redirect(conn, to: "/w/#{organization.slug}/#{workspace.slug}/pastes")

      {:error, :not_found} ->
        redirect(conn, to: ~p"/orgs")
    end
  end
end
