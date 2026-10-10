defmodule TextbinWeb.UI.DeletedLiveTest do
  use TextbinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Textbin.AccountsFixtures

  alias Textbin.Organizations
  alias Textbin.Pastes
  alias Textbin.Pastes.Paste
  alias Textbin.Repo

  setup %{conn: conn} do
    owner = user_fixture()
    workspace = personal_workspace_fixture(owner)
    {:ok, scope} = Organizations.resolve_workspace_scope(user_scope_fixture(owner), workspace)

    %{
      conn: log_in_user(conn, owner),
      owner: owner,
      scope: scope,
      path: "/w/#{scope.organization.slug}/#{workspace.slug}"
    }
  end

  test "lists deleted and expired pastes with their reason and time left", context do
    {:ok, deleted} = Pastes.create_paste(context.scope, %{data: "deleted paste"})
    {:ok, _} = Pastes.delete_paste(context.scope, deleted)
    {:ok, expired} = Pastes.create_paste(context.scope, %{data: "expired paste"})
    expire!(expired, -2)
    {:ok, active} = Pastes.create_paste(context.scope, %{data: "active paste"})

    {:ok, view, _html} = live(context.conn, "#{context.path}/deleted")

    assert has_element?(view, "#workspace-tab-deleted[aria-current='page']")
    assert has_element?(view, "#recovery-window-note", "30 days")
    assert has_element?(view, "#deleted-paste-title-#{deleted.id}", "deleted paste")
    assert has_element?(view, "#deleted-paste-reason-#{deleted.id}", "Deleted by you")
    assert has_element?(view, "#deleted-paste-days-left-#{deleted.id}", "in 30 days")
    assert has_element?(view, "#deleted-paste-reason-#{expired.id}", "Expired")
    assert has_element?(view, "#deleted-paste-days-left-#{expired.id}", "in 28 days")
    refute has_element?(view, "#deleted-paste-title-#{active.id}")
  end

  test "restore brings a paste back to the list", context do
    {:ok, paste} = Pastes.create_paste(context.scope, %{data: "bring me back"})
    {:ok, _} = Pastes.delete_paste(context.scope, paste)

    {:ok, view, _html} = live(context.conn, "#{context.path}/deleted")

    view |> element("#restore-paste-#{paste.id}") |> render_click()

    refute has_element?(view, "#deleted-paste-title-#{paste.id}")
    assert Pastes.get_paste(context.scope, paste.id)
  end

  test "delete now removes a paste for good", context do
    {:ok, paste} = Pastes.create_paste(context.scope, %{data: "gone for good"})
    {:ok, _} = Pastes.delete_paste(context.scope, paste)

    {:ok, view, _html} = live(context.conn, "#{context.path}/deleted")

    assert has_element?(view, "#delete-now-#{paste.id}[data-confirm]")
    view |> element("#delete-now-#{paste.id}") |> render_click()

    refute has_element?(view, "#deleted-paste-title-#{paste.id}")
    refute Repo.get(Paste, paste.id)
  end

  test "members see removed pastes but only act on their own", context do
    member = user_fixture()

    {:ok, _} =
      Organizations.add_organization_member(context.scope, context.scope.organization, member)

    {:ok, paste} = Pastes.create_paste(context.scope, %{data: "owner paste"})
    {:ok, _} = Pastes.delete_paste(context.scope, paste)

    {:ok, view, _html} = live(log_in_user(build_conn(), member), "#{context.path}/deleted")

    assert has_element?(view, "#deleted-paste-reason-#{paste.id}", context.owner.email)
    refute has_element?(view, "#restore-paste-#{paste.id}")
    refute has_element?(view, "#delete-now-#{paste.id}")
  end

  test "the empty state explains what shows up here", context do
    {:ok, view, _html} = live(context.conn, "#{context.path}/deleted")

    assert has_element?(view, "#deleted-pastes-empty", "Nothing deleted")
  end

  test "unjoined workspaces stay concealed", context do
    outsider = log_in_user(build_conn(), user_fixture())

    assert_raise Ecto.NoResultsError, fn ->
      live(outsider, "#{context.path}/deleted")
    end
  end

  defp expire!(paste, days) do
    paste
    |> Ecto.Changeset.change(expires_at: DateTime.add(Paste.utc_now_ms(), days, :day))
    |> Repo.update!()
  end
end
