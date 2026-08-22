defmodule Textbin.Administration.PlatformAuditEvent do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "platform_audit_events" do
    field :actor_kind, :string
    field :actor_user_id, :binary_id
    field :actor_label, :string
    field :action, :string
    field :target_type, :string
    field :target_id, :binary_id
    field :reason, :string
    field :request_id, :string
    field :metadata, :map, default: %{}
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :actor_kind,
      :actor_user_id,
      :actor_label,
      :action,
      :target_type,
      :target_id,
      :reason,
      :request_id,
      :metadata
    ])
    |> validate_required([
      :actor_kind,
      :actor_label,
      :action,
      :target_type,
      :target_id,
      :reason,
      :metadata
    ])
    |> validate_inclusion(:actor_kind, ["user", "bootstrap"])
    |> validate_length(:actor_label, max: 160)
    |> validate_length(:action, max: 100)
    |> validate_length(:target_type, max: 100)
    |> validate_length(:reason, max: 500)
    |> validate_length(:request_id, max: 255)
    |> check_constraint(:actor_kind,
      name: :platform_audit_events_actor_must_be_valid,
      message: "does not match the actor user"
    )
  end
end
