defmodule Textbin.Pastes.PendingUpload do
  use Ecto.Schema

  @primary_key {:storage_key, :string, autogenerate: false}

  schema "pending_uploads" do
    field :claimed_at, :utc_datetime_usec
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end
end
