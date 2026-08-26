defmodule TextbinWeb.UI.AdminLiveTest do
  use TextbinWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Textbin.AccountsFixtures

  alias Textbin.Accounts.Scope
  alias Textbin.Administration
  alias Textbin.Repo
  alias TextbinWeb.ForbiddenError

  test "requires authentication and current platform authority", %{conn: conn} do
    assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin")
    assert path == ~p"/users/log-in"

    user = user_fixture()

    assert_raise ForbiddenError, fn ->
      live(log_in_user(conn, user), ~p"/admin")
    end

    assert {:ok, :granted} = Administration.bootstrap_platform_admin(user.email)

    assert {:ok, view, _html} = live(log_in_user(conn, user), ~p"/admin")
    assert has_element?(view, "#admin-page")
    assert has_element?(view, "#admin-foundation-status")
  end

  test "leaves the panel promptly when current authority is revoked", %{conn: conn} do
    actor = platform_admin_fixture()
    target = platform_admin_fixture()
    target_conn = log_in_user(conn, target)

    assert {:ok, view, _html} = live(target_conn, ~p"/admin")
    monitor = monitor_proxy(view)

    assert {:ok, _target} =
             Administration.revoke_platform_admin(
               admin_scope(actor),
               target,
               "rotation complete"
             )

    assert_redirect(view, ~p"/")
    assert_full_redirect(monitor, ~p"/")
  end

  test "leaves the panel promptly when the administrator is suspended", %{conn: conn} do
    actor = platform_admin_fixture()
    target = platform_admin_fixture()

    assert {:ok, view, _html} = live(log_in_user(conn, target), ~p"/admin")
    monitor = monitor_proxy(view)

    assert {:ok, {_target, _tokens}} =
             Administration.suspend_user(admin_scope(actor), target, "security response")

    assert_redirect(view, ~p"/")
    assert_full_redirect(monitor, ~p"/")
  end

  defp monitor_proxy(%{proxy: {_ref, _topic, proxy_pid}}),
    do: {proxy_pid, Process.monitor(proxy_pid)}

  defp assert_full_redirect({proxy_pid, monitor_ref}, path) do
    assert_receive {:DOWN, ^monitor_ref, :process, ^proxy_pid,
                    {:shutdown, {:redirect, %{to: ^path}}}}
  end

  defp platform_admin_fixture do
    user = user_fixture()
    assert {:ok, :granted} = Administration.bootstrap_platform_admin(user.email)
    Repo.reload!(user)
  end

  defp admin_scope(user) do
    Scope.for_user(%{user | authenticated_at: DateTime.utc_now(:second)})
  end
end
