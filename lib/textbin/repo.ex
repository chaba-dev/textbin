defmodule Textbin.Repo do
  use Ecto.Repo,
    otp_app: :textbin,
    adapter: Ecto.Adapters.Postgres
end
