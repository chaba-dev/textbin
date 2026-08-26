defmodule TextbinWeb.UI.AdminLiveTest do
  use TextbinWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Textbin.AccountsFixtures

  alias Textbin.Accounts.Scope
  alias Textbin.Accounts.User
  alias Textbin.Administration
  alias Textbin.Administration.PlatformAuditEvent
  alias Textbin.Pastes
  alias Textbin.Pastes.Paste
  alias Textbin.Repo
  alias Textbin.Reports
  alias Textbin.Reports.Report
  alias TextbinWeb.ForbiddenError

  setup %{conn: conn} do
    admin = user_fixture()
    assert {:ok, :granted} = Administration.bootstrap_platform_admin(admin.email)
    admin = Repo.get!(Textbin.Accounts.User, admin.id)

    %{admin: admin, conn: log_in_user(conn, admin)}
  end

  test "requires authentication and current platform authority", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(build_conn(), ~p"/admin")

    ordinary_user = user_fixture()

    assert_raise ForbiddenError, fn ->
      ordinary_user
      |> then(&log_in_user(build_conn(), &1))
      |> live(~p"/admin")
    end

    assert {:ok, view, _html} = live(conn, ~p"/admin")
    assert has_element?(view, "#platform-admin-page")
  end

  test "renders bounded operational metadata without paste bodies", %{conn: conn} do
    owner = user_fixture()

    assert {:ok, paste} =
             Pastes.create_paste(Scope.for_user(owner), %{
               data: "highly-sensitive-body-marker",
               audience: "public"
             })

    assert {:ok, view, html} = live(conn, ~p"/admin")

    assert has_element?(view, "#installation-overview")
    assert has_element?(view, "#admin-lookup-form")
    assert has_element?(view, "#recent-public-pastes-entries a[href='/pastes/#{paste.id}']")
    assert has_element?(view, "#largest-pastes")
    assert has_element?(view, "#platform-audit-log")
    refute html =~ "highly-sensitive-body-marker"
  end

  test "looks up exact users and membership summaries", %{conn: conn} do
    target = user_fixture()
    assert {:ok, view, _html} = live(conn, ~p"/admin")

    view
    |> form("#admin-lookup-form", lookup: %{query: target.email})
    |> render_submit()

    assert has_element?(view, "#admin-user-result", target.email)
    refute has_element?(view, "#admin-lookup-empty")

    view
    |> form("#admin-lookup-form", lookup: %{query: "missing@example.com"})
    |> render_submit()

    assert has_element?(view, "#admin-lookup-empty")
  end

  test "performs reasoned account actions from an exact user lookup", %{conn: conn} do
    target = user_fixture()
    assert {:ok, view, _html} = live(conn, ~p"/admin")

    view
    |> form("#admin-lookup-form", lookup: %{query: target.email})
    |> render_submit()

    assert has_element?(view, "#admin-account-action-form")

    view
    |> form("#admin-account-action-form",
      account_action: %{
        action: "grant",
        target_id: target.id,
        reason: "incident response coverage"
      }
    )
    |> render_submit()

    assert_patch(view, ~p"/admin")
    assert Repo.get!(User, target.id).platform_role == "admin"
    refute has_element?(view, "#admin-user-result")
    refute has_element?(view, "#admin-account-action-form")
  end

  test "offers only eligible account actions", %{admin: admin, conn: conn} do
    unconfirmed = unconfirmed_user_fixture()
    assert {:ok, guest} = Textbin.Accounts.create_guest_user()
    assert {:ok, view, _html} = live(conn, ~p"/admin")

    view
    |> form("#admin-lookup-form", lookup: %{query: admin.email})
    |> render_submit()

    assert has_element?(view, "#admin-account-action option[value='revoke']")
    refute has_element?(view, "#admin-account-action option[value='suspend']")

    for target <- [unconfirmed, guest] do
      view
      |> form("#admin-lookup-form", lookup: %{query: target.email})
      |> render_submit()

      assert has_element?(view, "#admin-account-action option[value='suspend']")
      refute has_element?(view, "#admin-account-action option[value='grant']")
    end
  end

  test "removes a paste immediately and exposes its audit event", %{conn: conn} do
    owner = user_fixture()

    assert {:ok, paste} =
             Pastes.create_paste(Scope.for_user(owner), %{
               data: "reported content",
               audience: "public"
             })

    assert {:ok, view, _html} = live(conn, ~p"/admin")
    assert has_element?(view, "#admin-paste-moderation-form")

    view
    |> form("#admin-paste-moderation-form",
      moderation: %{paste_id: paste.id, reason: "reported malware"}
    )
    |> render_submit()

    assert_patch(view, ~p"/admin")
    assert %Paste{expires_at: %DateTime{}} = Repo.get!(Paste, paste.id)

    assert Repo.exists?(
             from event in PlatformAuditEvent,
               where:
                 event.action == "platform.paste.deleted" and event.target_id == ^paste.id and
                   event.reason == "reported malware"
           )
  end

  test "sensitive panel actions redirect stale sessions to reauthentication", %{conn: conn} do
    token = get_session(conn, :user_token)
    override_token_authenticated_at(token, DateTime.add(DateTime.utc_now(:second), -21, :minute))

    owner = user_fixture()
    assert {:ok, paste} = Pastes.create_paste(Scope.for_user(owner), %{data: "reported"})
    assert {:ok, view, _html} = live(conn, ~p"/admin")

    view
    |> form("#admin-paste-moderation-form",
      moderation: %{paste_id: paste.id, reason: "policy violation"}
    )
    |> render_submit()

    assert_redirect(view, ~p"/users/log-in")
    assert Repo.get!(Paste, paste.id).expires_at == nil
  end

  test "reviews reports without requiring sudo and refreshes the audit log", %{conn: conn} do
    owner = user_fixture()
    reporter = user_fixture()

    assert {:ok, paste} =
             Pastes.create_paste(Scope.for_user(owner), %{
               data: "reported from LiveView",
               audience: "unlisted"
             })

    assert {:ok, report} =
             Reports.create_report(Scope.for_user(reporter), paste.id, %{
               "category" => "malware",
               "notes" => "Unexpected executable"
             })

    token = get_session(conn, :user_token)
    override_token_authenticated_at(token, DateTime.add(DateTime.utc_now(:second), -21, :minute))

    assert {:ok, view, _html} = live(conn, ~p"/admin")
    assert has_element?(view, "#report-action-form-#{report.id}")
    assert has_element?(view, "#report-queue-entries", "Unexpected executable")
    assert has_element?(view, "#report-queue-entries a[href='/pastes/#{paste.id}']")

    view
    |> form("#report-action-form-#{report.id}",
      report_action: %{
        report_id: report.id,
        reason: "content removed by provider"
      }
    )
    |> put_submitter("#resolve-report-#{report.id}")
    |> render_submit()

    assert_patch(view, ~p"/admin")
    assert Repo.get!(Report, report.id).status == "actioned"
    refute has_element?(view, "#report-action-form-#{report.id}")
    assert has_element?(view, "#platform-audit-events", "Abuse report resolved")
  end

  test "surfaces final-admin and reason protections in the panel", %{
    admin: admin,
    conn: conn
  } do
    target = user_fixture()
    assert {:ok, view, _html} = live(conn, ~p"/admin")

    view
    |> form("#admin-lookup-form", lookup: %{query: admin.email})
    |> render_submit()

    view
    |> form("#admin-account-action-form",
      account_action: %{action: "revoke", target_id: admin.id, reason: "rotation"}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error", "final active administrator")
    assert Repo.get!(User, admin.id).platform_role == "admin"

    view
    |> form("#admin-lookup-form", lookup: %{query: target.email})
    |> render_submit()

    view
    |> form("#admin-account-action-form",
      account_action: %{action: "grant", target_id: target.id, reason: " "}
    )
    |> render_submit()

    assert has_element?(view, "#flash-error", "reason is required")
    assert Repo.get!(User, target.id).platform_role == nil
  end

  test "suspends and restores an account through audited panel actions", %{conn: conn} do
    target = user_fixture()
    target_token = Textbin.Accounts.generate_user_session_token(target)
    assert {:ok, view, _html} = live(conn, ~p"/admin")

    view
    |> form("#admin-lookup-form", lookup: %{query: target.email})
    |> render_submit()

    view
    |> form("#admin-account-action-form",
      account_action: %{action: "suspend", target_id: target.id, reason: "abuse response"}
    )
    |> render_submit()

    assert_patch(view, ~p"/admin")
    assert %User{suspended_at: %DateTime{}} = Repo.get!(User, target.id)
    refute Textbin.Accounts.get_user_by_session_token(target_token)
    assert has_element?(view, "#platform-audit-events", "Account suspended")

    view
    |> form("#admin-lookup-form", lookup: %{query: target.email})
    |> render_submit()

    view
    |> form("#admin-account-action-form",
      account_action: %{action: "restore", target_id: target.id, reason: "appeal accepted"}
    )
    |> render_submit()

    assert_patch(view, ~p"/admin")
    assert Repo.get!(User, target.id).suspended_at == nil
    assert has_element?(view, "#platform-audit-events", "Account restored")
  end

  test "renders every protected largest-paste row without exposing capability IDs", %{conn: conn} do
    owner = user_fixture()
    scope = Scope.for_user(owner)

    assert {:ok, first} =
             Pastes.create_paste(scope, %{
               data: String.duplicate("a", 200),
               audience: "unlisted"
             })

    assert {:ok, second} =
             Pastes.create_paste(scope, %{
               data: String.duplicate("b", 100),
               audience: "workspace"
             })

    assert {:ok, view, _html} = live(conn, ~p"/admin")

    assert has_element?(view, "#largest-pastes-entries article + article")
    refute has_element?(view, "#largest-pastes-entries a[href='/pastes/#{first.id}']")
    refute has_element?(view, "#largest-pastes-entries a[href='/pastes/#{second.id}']")

    row_ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#largest-pastes-entries article")
      |> LazyHTML.attribute("id")

    assert length(row_ids) == 2
    assert length(Enum.uniq(row_ids)) == 2
  end

  test "leaves the panel promptly when authority is revoked", %{admin: admin, conn: conn} do
    actor = user_fixture()
    assert {:ok, :granted} = Administration.bootstrap_platform_admin(actor.email)
    actor = Repo.get!(Textbin.Accounts.User, actor.id)
    actor_scope = Scope.for_user(%{actor | authenticated_at: DateTime.utc_now(:second)})

    assert {:ok, view, _html} = live(conn, ~p"/admin")
    monitor = monitor_proxy(view)

    assert {:ok, _revoked} =
             Administration.revoke_platform_admin(actor_scope, admin, "operator rotation")

    assert_redirect(view, ~p"/")
    assert_full_redirect(monitor, ~p"/")
  end

  test "leaves the panel promptly when the administrator is suspended", %{
    admin: admin,
    conn: conn
  } do
    actor = user_fixture()
    assert {:ok, :granted} = Administration.bootstrap_platform_admin(actor.email)
    actor = Repo.get!(Textbin.Accounts.User, actor.id)
    actor_scope = Scope.for_user(%{actor | authenticated_at: DateTime.utc_now(:second)})

    assert {:ok, view, _html} = live(conn, ~p"/admin")
    monitor = monitor_proxy(view)

    assert {:ok, {_target, _tokens}} =
             Administration.suspend_user(actor_scope, admin, "security response")

    assert_redirect(view, ~p"/")
    assert_full_redirect(monitor, ~p"/")
  end

  defp monitor_proxy(%{proxy: {_ref, _topic, proxy_pid}}),
    do: {proxy_pid, Process.monitor(proxy_pid)}

  defp assert_full_redirect({proxy_pid, monitor_ref}, path) do
    assert_receive {:DOWN, ^monitor_ref, :process, ^proxy_pid,
                    {:shutdown, {:redirect, %{to: ^path}}}}
  end
end
