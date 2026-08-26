# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Textbin.Repo.insert!(%Textbin.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.

if Mix.env() == :prod do
  raise "refusing to seed known development credentials in production"
end

alias Textbin.Accounts
alias Textbin.Accounts.User
alias Textbin.Administration
alias Textbin.Repo

password = "supersecure!"

emails = [
  "test@example.com",
  "alex@example.com",
  "blair@example.com",
  "casey@example.com",
  "devon@example.com",
  "ellis@example.com",
  "frankie@example.com",
  "gray@example.com",
  "harper@example.com",
  "jules@example.com"
]

seed_user = fn email ->
  user =
    case Accounts.get_user_by_email(email) do
      nil ->
        {:ok, user} = Accounts.register_user(%{email: email})
        user

      %User{} = user ->
        user
    end

  user =
    if user.confirmed_at do
      user
    else
      user
      |> User.confirm_changeset()
      |> Repo.update!()
    end

  {:ok, {user, _expired_tokens}} =
    Accounts.update_user_password(user, %{password: password})

  user
end

Enum.each(emails, seed_user)

{:ok, admin_result} = Administration.bootstrap_platform_admin("test@example.com")

IO.puts("Seeded #{length(emails)} development users with password #{inspect(password)}.")
IO.puts("test@example.com platform admin: #{admin_result}")
