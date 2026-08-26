defmodule TextbinWeb.HealthControllerTest do
  use TextbinWeb.ConnCase, async: true

  test "GET /healthz reports process liveness", %{conn: conn} do
    conn = get(conn, ~p"/healthz")

    assert response(conn, 200) == "ok\n"
  end

  test "GET /readyz reports PostgreSQL readiness", %{conn: conn} do
    conn = get(conn, ~p"/readyz")

    assert response(conn, 200) == "ready\n"
  end
end
