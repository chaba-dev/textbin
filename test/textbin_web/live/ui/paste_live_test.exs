defmodule TextbinWeb.UI.PasteLiveTest do
  use TextbinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Textbin.AccountsFixtures

  alias Textbin.Organizations
  alias Textbin.Organizations.Workspace
  alias Textbin.Pastes.Paste
  alias Textbin.Pastes
  alias Textbin.Repo

  setup %{conn: conn} do
    user = user_fixture()
    %{conn: log_in_user(conn, user), scope: user_scope_fixture(user), user: user}
  end

  test "redirects unauthenticated users to login" do
    assert {:error, {:redirect, %{to: path, flash: flash}}} = live(build_conn(), ~p"/pastes")
    assert path == ~p"/users/log-in"
    assert %{"error" => "You must log in to access this page."} = flash
  end

  test "redirects the legacy index to the user's default workspace", %{
    conn: conn,
    user: user
  } do
    assert {:error, {:live_redirect, %{to: path}}} = live(conn, ~p"/pastes")
    assert path == personal_workspace_path(user)
  end

  test "allows guest paste creation when enabled" do
    put_guest_pastes_enabled(true)

    conn = get(build_conn(), ~p"/pastes")
    path = redirected_to(conn)
    assert path =~ ~r{^/w/personal-[0-9a-f-]+/default/pastes$}
    {:ok, view, _html} = live(recycle(conn), path)

    assert has_element?(view, "#paste-form")
    assert has_element?(view, "#paste_audience[disabled] option[value='unlisted']")
    refute has_element?(view, "#organization-overview-link")

    view
    |> form("#paste-form", %{
      "paste" => %{
        "data" => "guest paste",
        "syntax_highlight" => "plain",
        "expires_in" => ""
      }
    })
    |> render_submit()

    paste =
      Paste
      |> Repo.one!()
      |> Pastes.load_data()
      |> Repo.preload(:created_by_user)

    assert paste.data == "guest paste"
    assert paste.created_by_user.kind == "guest"
    assert paste.audience == "unlisted"
    assert DateTime.diff(paste.expires_at, DateTime.utc_now(), :second) in 21_590..21_600
    assert has_element?(view, "##{stream_id(paste)}", "plain")
  end

  test "lists scoped pastes", %{conn: conn, scope: scope, user: user} do
    {:ok, paste} =
      Pastes.create_paste(scope, %{data: "live paste data", syntax_highlight: "elixir"})

    {:ok, other_paste} =
      Pastes.create_paste(user_scope_fixture(), %{data: "other user data"})

    {path, {:ok, view, _html}} = live_personal_workspace(conn, user)
    organization = Organizations.get_personal_organization!(user)

    assert has_element?(view, "#pastes-list")

    assert has_element?(
             view,
             "#organization-overview-link[href='/o/#{organization.slug}']"
           )

    assert has_element?(view, "##{stream_id(paste)}", paste.id)
    assert has_element?(view, "##{stream_id(paste)}", "elixir")
    assert has_element?(view, "#paste-audience-#{paste.id}", "Workspace")
    assert has_element?(view, "#paste-expires-at-#{paste.id}", "Never expires")
    assert has_element?(view, "##{stream_id(paste)} a[href='#{path}/#{paste.id}']")
    refute has_element?(view, "##{stream_id(paste)}", "live paste data")
    refute has_element?(view, "##{stream_id(other_paste)}")
  end

  test "renders an empty state", %{conn: conn, user: user} do
    {_path, {:ok, view, _html}} = live_personal_workspace(conn, user)

    assert has_element?(view, "#pastes-list")
    assert has_element?(view, "#pastes-empty.min-h-56.text-base", "No pastes yet.")
  end

  test "workspace URLs restore the selected scope and conceal other workspace pastes", %{
    conn: conn,
    scope: scope
  } do
    {organization, first_workspace, second_workspace} = team_workspaces(scope)
    first_scope = workspace_scope(scope, first_workspace)
    second_scope = workspace_scope(scope, second_workspace)
    {:ok, first_paste} = Pastes.create_paste(first_scope, %{data: "first workspace"})
    {:ok, second_paste} = Pastes.create_paste(second_scope, %{data: "second workspace"})
    path = workspace_path(organization, second_workspace)

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "##{stream_id(second_paste)}")
    refute has_element?(view, "##{stream_id(first_paste)}")
    assert has_element?(view, "##{stream_id(second_paste)} a[href='#{path}/#{second_paste.id}']")

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, "#{path}/#{first_paste.id}")
    end
  end

  test "creates pastes in the workspace selected by the URL", %{conn: conn, scope: scope} do
    {organization, _default_workspace, workspace} = team_workspaces(scope)
    path = workspace_path(organization, workspace)
    {:ok, view, _html} = live(conn, path)

    view
    |> form("#paste-form", %{
      "paste" => %{
        "data" => "team paste",
        "syntax_highlight" => "plain",
        "audience" => "workspace",
        "expires_in" => "never"
      }
    })
    |> render_submit()

    assert [paste] = Pastes.list_pastes(workspace_scope(scope, workspace))
    assert paste.data == "team paste"
    assert paste.workspace_id == workspace.id
    assert has_element?(view, "##{stream_id(paste)} a[href='#{path}/#{paste.id}']")
  end

  test "revoked workspace membership prevents creation from an already connected view", %{
    scope: owner_scope
  } do
    member = user_fixture()
    {organization, _default_workspace, workspace} = team_workspaces(owner_scope)

    {:ok, _organization_memberships} =
      Organizations.add_organization_member(owner_scope, organization, member)

    {:ok, membership} =
      Organizations.add_workspace_member(owner_scope, workspace, member)

    conn = log_in_user(build_conn(), member)
    {:ok, view, _html} = live(conn, workspace_path(organization, workspace))
    Repo.delete!(membership)

    view
    |> form("#paste-form", %{
      "paste" => %{
        "data" => "created after revocation",
        "syntax_highlight" => "plain",
        "audience" => "workspace",
        "expires_in" => "never"
      }
    })
    |> render_submit()

    refute Repo.get_by(Paste, workspace_id: workspace.id, data: "created after revocation")
  end

  test "switching workspaces navigates to a server-owned URL and clears the previous stream", %{
    conn: conn,
    scope: scope
  } do
    {organization, first_workspace, second_workspace} = team_workspaces(scope)

    {:ok, first_paste} =
      Pastes.create_paste(workspace_scope(scope, first_workspace), %{data: "first"})

    {:ok, second_paste} =
      Pastes.create_paste(workspace_scope(scope, second_workspace), %{data: "second"})

    {:ok, view, _html} = live(conn, workspace_path(organization, first_workspace))
    assert has_element?(view, "##{stream_id(first_paste)}")

    redirect =
      view
      |> form("#workspace-switcher", %{"workspace" => %{"id" => second_workspace.id}})
      |> render_change()

    destination = workspace_path(organization, second_workspace)
    assert_redirect(view, destination)
    {:ok, switched_view, _html} = follow_redirect(redirect, conn, destination)
    assert has_element?(switched_view, "##{stream_id(second_paste)}")
    refute has_element?(switched_view, "##{stream_id(first_paste)}")
  end

  test "workspace navigation includes joined workspaces across organizations but not unjoined ones",
       %{
         conn: conn,
         scope: scope
       } do
    {organization, default_workspace, _joined_workspace} = team_workspaces(scope)

    {:ok, hidden_open} =
      Organizations.create_workspace(scope, organization, %{
        name: "Discoverable",
        slug: "discoverable",
        visibility: "open"
      })

    hidden_private =
      Repo.insert!(%Workspace{
        organization_id: organization.id,
        created_by_id: scope.user.id,
        name: "Hidden",
        slug: "hidden",
        visibility: "private",
        is_default: false
      })

    # Removing the creator memberships simulates workspaces visible through
    # discovery but unavailable in the active workspace switcher.
    Repo.delete_all(Ecto.assoc(hidden_open, :memberships))

    {:ok, view, _html} = live(conn, workspace_path(organization, default_workspace))
    assert has_element?(view, "#workspace-switcher option", "Personal / Default")
    assert has_element?(view, "#workspace-switcher option", "Navigation team / Default")
    refute has_element?(view, "#workspace-switcher option[value='#{hidden_open.id}']")
    refute has_element?(view, "#workspace-switcher option[value='#{hidden_private.id}']")

    for workspace <- [hidden_open, hidden_private] do
      assert_raise Ecto.NoResultsError, fn ->
        live(conn, workspace_path(organization, workspace))
      end
    end
  end

  test "creates a paste from the UI", %{conn: conn, scope: scope, user: user} do
    {_path, {:ok, view, _html}} = live_personal_workspace(conn, user)

    assert has_element?(view, "#paste-form")
    assert has_element?(view, "#paste_audience option[value='workspace']")
    assert has_element?(view, "#paste_audience option[value='unlisted']")
    assert has_element?(view, "#paste_audience option[value='public']")

    view
    |> form("#paste-form", %{
      "paste" => %{
        "data" => "created from the browser",
        "syntax_highlight" => "markdown",
        "audience" => "public",
        "expires_in" => "never"
      }
    })
    |> render_submit()

    assert [paste] = Pastes.list_pastes(scope)
    assert paste.data == "created from the browser"
    assert paste.syntax_highlight == "markdown"
    assert paste.audience == "public"
    assert is_nil(paste.expires_at)
    assert has_element?(view, "##{stream_id(paste)}", "markdown")
    assert has_element?(view, "#paste-audience-#{paste.id}", "Public")
  end

  test "form validation revalidates the workspace resolved at mount", %{conn: conn, user: user} do
    {_path, {:ok, view, _html}} = live_personal_workspace(conn, user)
    handler_id = "paste-form-query-test-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:textbin, :repo, :query],
      fn _event, _measurements, metadata, test_pid ->
        send(test_pid, {:repo_query, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    for data <- ["a", "ab"] do
      view
      |> form("#paste-form", %{
        "paste" => %{"data" => data, "syntax_highlight" => "plain", "expires_in" => ""}
      })
      |> render_change()
    end

    assert_receive {:repo_query, _metadata}, 100
  end

  test "creates a paste with the user's default expiration", %{scope: scope} do
    {:ok, user} =
      Textbin.Accounts.update_user_paste_defaults(scope.user, %{default_paste_ttl: "1h"})

    scope = %{scope | user: user}
    conn = log_in_user(build_conn(), user)

    {_path, {:ok, view, _html}} = live_personal_workspace(conn, user)

    view
    |> form("#paste-form", %{
      "paste" => %{
        "data" => "uses account default",
        "syntax_highlight" => "plain",
        "expires_in" => ""
      }
    })
    |> render_submit()

    assert [paste] = Pastes.list_pastes(scope)
    assert DateTime.diff(paste.expires_at, DateTime.utc_now(), :second) in 3590..3600
    assert has_element?(view, "#paste-expires-at-#{paste.id}", "Expires")
  end

  test "shows an individual paste", %{conn: conn, scope: scope, user: user} do
    {:ok, paste} =
      Pastes.create_paste(scope, %{data: "individual paste data", syntax_highlight: "json"})

    {:ok, view, _html} = live(conn, ~p"/pastes/#{paste.id}")

    assert has_element?(view, "h1", paste.id)
    assert has_element?(view, "span", "json")
    assert has_element?(view, "#paste-audience", "Workspace")
    assert has_element?(view, "#paste-expires-at", "Never expires")
    assert has_element?(view, "#paste-data .lumis code.language-json")
    assert has_element?(view, "#paste-data .l-line[data-line='1']")
    assert has_element?(view, "#paste-data", "individual paste data")
    assert has_element?(view, "a[href='#{personal_workspace_path(user)}']", "Back to pastes")
    assert has_element?(view, "#copy-paste-content[phx-hook='CopyToClipboard']")
    assert has_element?(view, "#raw-paste-link[href='/pastes/#{paste.id}/raw']")
    assert has_element?(view, "#delete-paste-#{paste.id}")
  end

  test "renders HTML paste content as escaped source", %{conn: conn, scope: scope} do
    {:ok, paste} =
      Pastes.create_paste(scope, %{
        data: "<script id=\"injected\">alert('unsafe')</script>",
        content_type: "text/html",
        audience: "public"
      })

    {:ok, view, _html} = live(conn, ~p"/pastes/#{paste.id}")

    assert has_element?(view, "#paste-content-type", "text/html")
    assert has_element?(view, "#paste-data", "alert('unsafe')")
    refute has_element?(view, "#paste-data script#injected")
  end

  test "does not render or copy binary paste content", %{conn: conn, scope: scope} do
    {:ok, paste} =
      Pastes.create_paste(scope, %{data: <<255, 0, 1>>, visibility: "public"})

    {:ok, view, _html} = live(conn, ~p"/pastes/#{paste.id}")

    assert has_element?(view, "#paste-content-type", "application/octet-stream")
    assert has_element?(view, "#paste-binary-data", "Binary paste")
    refute has_element?(view, "#paste-data")
    refute has_element?(view, "#copy-paste-content")
  end

  test "anonymous viewers can open unlisted and public pastes", %{scope: scope} do
    for visibility <- ["unlisted", "public"] do
      {:ok, paste} =
        Pastes.create_paste(scope, %{
          data: "#{visibility} paste",
          syntax_highlight: "elixir",
          visibility: visibility
        })

      {:ok, view, _html} = live(build_conn(), ~p"/pastes/#{paste.id}")

      assert has_element?(view, "#paste-audience", String.capitalize(visibility))
      assert has_element?(view, "#paste-data .l-line[data-line='1']")
      assert has_element?(view, "#paste-data", "#{visibility} paste")
      assert has_element?(view, "#copy-paste-content[phx-hook='CopyToClipboard']")
      assert has_element?(view, "#raw-paste-link[href='/pastes/#{paste.id}/raw']")
      refute has_element?(view, "a[href='/pastes']", "Back to pastes")
      refute has_element?(view, "#delete-paste-#{paste.id}")
    end
  end

  test "private pastes are hidden from anonymous and other signed-in viewers", %{scope: scope} do
    {:ok, paste} = Pastes.create_paste(scope, %{data: "private paste", visibility: "private"})

    assert_raise Ecto.NoResultsError, fn ->
      live(build_conn(), ~p"/pastes/#{paste.id}")
    end

    other_user = user_fixture()

    assert_raise Ecto.NoResultsError, fn ->
      live(log_in_user(build_conn(), other_user), ~p"/pastes/#{paste.id}")
    end
  end

  test "shared HTML enforces disabled sharing for an inconsistent public row", %{scope: scope} do
    workspace = personal_workspace_fixture(scope.user)

    {:ok, workspace} =
      Organizations.change_workspace_settings(scope, workspace, %{
        external_sharing_policy: "disabled"
      })

    paste =
      Repo.insert!(%Paste{
        data: "internal page",
        audience: "public",
        workspace_id: workspace.id,
        created_by_user_id: scope.user.id
      })

    assert_raise Ecto.NoResultsError, fn ->
      live(build_conn(), ~p"/pastes/#{paste.id}")
    end
  end

  test "copy button exposes the exact stored paste data", %{scope: scope} do
    for data <- ["abc", "abc\n"] do
      {:ok, paste} =
        Pastes.create_paste(scope, %{data: data, syntax_highlight: "plain", visibility: "public"})

      {:ok, view, _html} = live(build_conn(), ~p"/pastes/#{paste.id}")

      copy_button =
        view
        |> element("#copy-paste-content")
        |> render()
        |> LazyHTML.from_fragment()

      assert LazyHTML.attribute(copy_button, "data-copy-content") == [data]
      assert has_element?(view, "#copy-paste-content[phx-update='ignore']")
    end
  end

  test "escapes paste data before rendering highlighted HTML", %{conn: conn, scope: scope} do
    {:ok, paste} =
      Pastes.create_paste(scope, %{
        data: "<script>alert('nope')</script>",
        syntax_highlight: "plain"
      })

    {:ok, view, _html} = live(conn, ~p"/pastes/#{paste.id}")

    assert has_element?(view, "#paste-data .lumis code.language-plaintext")
    assert has_element?(view, "#paste-data", "<script>alert('nope')</script>")
    refute has_element?(view, "#paste-data script")
  end

  test "deletes a paste from the list", %{conn: conn, scope: scope, user: user} do
    {:ok, paste} = Pastes.create_paste(scope, %{data: "delete from list"})

    {_path, {:ok, view, _html}} = live_personal_workspace(conn, user)

    assert has_element?(
             view,
             "#delete-paste-#{paste.id}[data-confirm='Delete this paste?']"
           )

    view
    |> element("#delete-paste-#{paste.id}")
    |> render_click()

    refute has_element?(view, "##{stream_id(paste)}")
    assert_raise Ecto.NoResultsError, fn -> Pastes.get_paste!(scope, paste.id) end
  end

  test "workspace members only see delete controls for their own pastes", %{scope: owner_scope} do
    member = user_fixture()
    organization = Organizations.get_personal_organization!(owner_scope.user)
    workspace = personal_workspace_fixture(owner_scope.user)

    {:ok, _memberships} =
      Organizations.add_organization_member(owner_scope, organization, member)

    owner_paste =
      Repo.insert!(%Paste{
        data: "owner paste",
        workspace_id: workspace.id,
        created_by_user_id: owner_scope.user.id
      })

    member_paste =
      Repo.insert!(%Paste{
        data: "member paste",
        workspace_id: workspace.id,
        created_by_user_id: member.id
      })

    conn = log_in_user(build_conn(), member)
    {:ok, view, _html} = live(conn, workspace_path(organization, workspace))

    refute has_element?(view, "#delete-paste-#{owner_paste.id}")
    assert has_element?(view, "#delete-paste-#{member_paste.id}")
  end

  test "delete events cannot target a paste outside the active workspace", %{
    conn: conn,
    scope: scope
  } do
    {organization, first_workspace, second_workspace} = team_workspaces(scope)

    {:ok, second_paste} =
      Pastes.create_paste(workspace_scope(scope, second_workspace), %{data: "keep me"})

    {:ok, view, _html} = live(conn, workspace_path(organization, first_workspace))
    render_click(view, "delete", %{"id" => second_paste.id})

    assert Repo.get(Paste, second_paste.id)
  end

  test "deletes a paste from the detail page", %{conn: conn, scope: scope, user: user} do
    {:ok, paste} = Pastes.create_paste(scope, %{data: "delete from detail"})

    {:ok, view, _html} = live(conn, ~p"/pastes/#{paste.id}")

    assert has_element?(
             view,
             "#delete-paste-#{paste.id}[data-confirm='Delete this paste?']"
           )

    view
    |> element("#delete-paste-#{paste.id}")
    |> render_click()

    assert_redirect(view, personal_workspace_path(user))
    assert_raise Ecto.NoResultsError, fn -> Pastes.get_paste!(scope, paste.id) end
  end

  test "workspace owner deletes a member's paste from the detail page", %{
    conn: conn,
    scope: owner_scope
  } do
    member = user_fixture()
    organization = Organizations.get_personal_organization!(owner_scope.user)
    workspace = personal_workspace_fixture(owner_scope.user)

    assert {:ok, _memberships} =
             Organizations.add_organization_member(owner_scope, organization, member)

    paste =
      Repo.insert!(%Paste{
        data: "member paste",
        workspace_id: workspace.id,
        created_by_user_id: member.id
      })

    {:ok, view, _html} = live(conn, ~p"/pastes/#{paste.id}")
    assert has_element?(view, "#delete-paste-#{paste.id}")

    view
    |> element("#delete-paste-#{paste.id}")
    |> render_click()

    assert_redirect(view, personal_workspace_path(owner_scope.user))
    refute Repo.get(Paste, paste.id)
  end

  test "workspace member deletes their own paste from the detail page", %{scope: owner_scope} do
    member = user_fixture()
    member_scope = user_scope_fixture(member)
    organization = Organizations.get_personal_organization!(owner_scope.user)
    workspace = personal_workspace_fixture(owner_scope.user)

    assert {:ok, _memberships} =
             Organizations.add_organization_member(owner_scope, organization, member)

    paste =
      Repo.insert!(%Paste{
        data: "member paste",
        workspace_id: workspace.id,
        created_by_user_id: member.id
      })

    conn = log_in_user(build_conn(), member)
    {:ok, view, _html} = live(conn, ~p"/pastes/#{paste.id}")
    assert Pastes.manage_paste?(member_scope, paste)
    assert has_element?(view, "#delete-paste-#{paste.id}")

    view
    |> element("#delete-paste-#{paste.id}")
    |> render_click()

    assert_redirect(view, personal_workspace_path(owner_scope.user))
    refute Repo.get(Paste, paste.id)
  end

  test "workspace member cannot delete another member's paste", %{scope: owner_scope} do
    member = user_fixture()
    organization = Organizations.get_personal_organization!(owner_scope.user)
    workspace = personal_workspace_fixture(owner_scope.user)

    assert {:ok, _memberships} =
             Organizations.add_organization_member(owner_scope, organization, member)

    paste =
      Repo.insert!(%Paste{
        data: "owner paste",
        workspace_id: workspace.id,
        created_by_user_id: owner_scope.user.id
      })

    conn = log_in_user(build_conn(), member)
    {:ok, view, _html} = live(conn, ~p"/pastes/#{paste.id}")
    refute has_element?(view, "#delete-paste-#{paste.id}")

    render_click(view, "delete", %{"id" => paste.id})
    assert Repo.get(Paste, paste.id)
  end

  test "revoked workspace membership prevents deletion", %{scope: owner_scope} do
    member = user_fixture()
    organization = Organizations.get_personal_organization!(owner_scope.user)
    workspace = personal_workspace_fixture(owner_scope.user)

    assert {:ok, _memberships} =
             Organizations.add_organization_member(owner_scope, organization, member)

    paste =
      Repo.insert!(%Paste{
        data: "member paste",
        workspace_id: workspace.id,
        created_by_user_id: member.id
      })

    conn = log_in_user(build_conn(), member)
    {:ok, view, _html} = live(conn, ~p"/pastes/#{paste.id}")
    assert has_element?(view, "#delete-paste-#{paste.id}")

    workspace
    |> Ecto.assoc(:memberships)
    |> Repo.get_by!(user_id: member.id)
    |> Repo.delete!()

    render_click(view, "delete", %{"id" => paste.id})
    assert Repo.get(Paste, paste.id)
  end

  defp stream_id(paste), do: "pastes-#{paste.id}"

  defp live_personal_workspace(conn, user) do
    path = personal_workspace_path(user)
    {path, live(conn, path)}
  end

  defp personal_workspace_path(user) do
    organization = Organizations.get_personal_organization!(user)
    workspace = Enum.find(organization.workspaces, & &1.is_default)
    "/w/#{organization.slug}/#{workspace.slug}/pastes"
  end

  defp team_workspaces(scope) do
    slug = "navigation-#{System.unique_integer([:positive])}"

    {:ok, organization} =
      Organizations.create_organization(scope, %{name: "Navigation team", slug: slug})

    [default_workspace] = organization.workspaces

    {:ok, workspace} =
      Organizations.create_workspace(scope, organization, %{
        name: "Engineering",
        slug: "engineering",
        visibility: "private"
      })

    {organization, default_workspace, workspace}
  end

  defp workspace_scope(scope, workspace) do
    {:ok, resolved_scope} = Organizations.resolve_workspace_scope(scope, workspace)
    resolved_scope
  end

  defp workspace_path(organization, workspace) do
    "/w/#{organization.slug}/#{workspace.slug}/pastes"
  end

  defp put_guest_pastes_enabled(enabled?) do
    previous = Application.get_env(:textbin, :allow_guest_pastes)
    Application.put_env(:textbin, :allow_guest_pastes, enabled?)

    on_exit(fn ->
      Application.put_env(:textbin, :allow_guest_pastes, previous)
    end)
  end
end
