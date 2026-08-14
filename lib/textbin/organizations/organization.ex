defmodule Textbin.Organizations.Organization do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @kinds ["personal", "team"]

  schema "organizations" do
    field :name, :string
    field :slug, :string
    field :kind, :string
    field :deletion_requested_at, :utc_datetime_usec

    belongs_to :personal_owner, Textbin.Accounts.User
    has_many :memberships, Textbin.Organizations.OrganizationMembership
    has_many :workspaces, Textbin.Organizations.Workspace

    timestamps(type: :utc_datetime)
  end

  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:name, :slug])
    |> validate_required([:name, :slug, :kind])
    |> validate_length(:name, max: 160)
    |> validate_length(:slug, max: 100)
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
    |> validate_inclusion(:kind, @kinds)
    |> validate_personal_owner()
    |> unique_constraint(:slug)
    |> unique_constraint(:personal_owner_id)
    |> foreign_key_constraint(:personal_owner_id)
  end

  defp validate_personal_owner(changeset) do
    case {get_field(changeset, :kind), get_field(changeset, :personal_owner_id)} do
      {"personal", nil} ->
        add_error(changeset, :personal_owner, "can't be blank")

      {"team", owner_id} when not is_nil(owner_id) ->
        add_error(changeset, :personal_owner, "must be blank")

      _other ->
        changeset
    end
  end
end
