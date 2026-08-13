defmodule Textbin.Organizations.OrganizationMembership do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @roles ["owner", "admin", "member"]

  schema "organization_memberships" do
    field :role, :string

    belongs_to :organization, Textbin.Organizations.Organization
    belongs_to :user, Textbin.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(membership) do
    membership
    |> change()
    |> validate_required([:organization_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:organization_id, :user_id])
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:user_id)
  end

  def role_changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> validate_inclusion(:role, @roles)
  end
end
