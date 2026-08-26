defmodule TextbinWeb.HealthController do
  use TextbinWeb, :controller

  @database_timeout 2_000

  @doc "Reports whether the HTTP process is running without checking dependencies."
  def live(conn, _params) do
    send_resp(conn, :ok, "ok\n")
  end

  @doc "Reports whether the application can serve requests that require PostgreSQL."
  def ready(conn, _params) do
    case Textbin.Repo.query("SELECT 1", [],
           timeout: @database_timeout,
           pool_timeout: @database_timeout
         ) do
      {:ok, _result} -> send_resp(conn, :ok, "ready\n")
      {:error, _reason} -> send_resp(conn, :service_unavailable, "unavailable\n")
    end
  end
end
