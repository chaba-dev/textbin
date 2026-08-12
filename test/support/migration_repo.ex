defmodule Textbin.MigrationRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :textbin,
    adapter: Ecto.Adapters.Postgres
end
