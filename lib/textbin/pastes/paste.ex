defmodule Textbin.Pastes.Paste do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Store timestamps at millisecond precision so API output and database values
  # stay stable across adapters and reloads.
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {__MODULE__, :utc_now_ms, []}]
  schema "pastes" do
    field :data, :string
    field :syntax_highlight, :string, default: "plain"

    belongs_to :user, Textbin.Accounts.User

    timestamps()
  end

  def changeset(paste, attrs) do
    paste
    |> cast(attrs, [:data, :syntax_highlight])
    |> validate_required([:data, :syntax_highlight, :user_id])
  end

  def utc_now_ms do
    # Ecto's :utc_datetime_usec type expects six-digit precision metadata even
    # when the value itself is intentionally millisecond-aligned.
    %{microsecond: {microsecond, 3}} =
      timestamp = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    %{timestamp | microsecond: {microsecond, 6}}
  end
end
