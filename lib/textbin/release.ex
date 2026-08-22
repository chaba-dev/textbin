defmodule Textbin.Release do
  @moduledoc """
  Runtime tasks intended to be invoked from a packaged OTP release.
  """

  @app :textbin

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _process, _apps} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc "Grants platform administration authority to a confirmed existing user."
  def grant_platform_admin(email) when is_binary(email) do
    Textbin.Administration.bootstrap_platform_admin(email)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
