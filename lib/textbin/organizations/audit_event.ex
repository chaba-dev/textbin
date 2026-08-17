defmodule Textbin.Organizations.AuditEvent do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "audit_events" do
    field :organization_id, :binary_id
    field :actor_user_id, :binary_id
    field :action, :string
    field :target_type, :string
    field :target_id, :binary_id
    field :metadata, :map, default: %{}

    belongs_to :actor, Textbin.Accounts.User,
      foreign_key: :actor_user_id,
      define_field: false

    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :organization_id,
      :actor_user_id,
      :action,
      :target_type,
      :target_id,
      :metadata
    ])
    |> validate_required([
      :organization_id,
      :actor_user_id,
      :action,
      :target_type,
      :target_id,
      :metadata
    ])
  end
end
