defmodule Textbin.Pastes.Paste do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {__MODULE__, :utc_now_ms, []}]
  schema "pastes" do
    field :content, :string

    timestamps()
  end

  def changeset(paste, attrs) do
    paste
    |> cast(attrs, [:content])
    |> validate_required([:content])
  end

  def utc_now_ms do
    %{microsecond: {microsecond, 3}} =
      timestamp = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    %{timestamp | microsecond: {microsecond, 6}}
  end
end
