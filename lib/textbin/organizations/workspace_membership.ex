defmodule Textbin.Organizations.WorkspaceMembership do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @roles ["owner", "member"]

  schema "workspace_memberships" do
    field :role, :string

    belongs_to :workspace, Textbin.Organizations.Workspace
    belongs_to :user, Textbin.Accounts.User
    belongs_to :created_by, Textbin.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(membership) do
    membership
    |> change()
    |> validate_required([:workspace_id, :user_id, :role])
    |> validate_inclusion(:role, @roles)
    |> unique_constraint([:workspace_id, :user_id])
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:created_by_id)
  end

  def role_changeset(membership, attrs) do
    membership
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> validate_inclusion(:role, @roles)
  end
end
