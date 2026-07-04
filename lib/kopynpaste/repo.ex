defmodule Kopynpaste.Repo do
  use Ecto.Repo,
    otp_app: :kopynpaste,
    adapter: Ecto.Adapters.Postgres
end
