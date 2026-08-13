defmodule Textbin.Organizations.Workspace do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @visibilities ["open", "private"]

  schema "workspaces" do
    field :name, :string
    field :slug, :string
    field :visibility, :string, default: "open"
    field :is_default, :boolean, default: false

    belongs_to :organization, Textbin.Organizations.Organization
    belongs_to :created_by, Textbin.Accounts.User
    has_many :memberships, Textbin.Organizations.WorkspaceMembership
    has_many :pastes, Textbin.Pastes.Paste

    timestamps(type: :utc_datetime)
  end

  def changeset(workspace, attrs) do
    workspace
    |> cast(attrs, [:name, :slug, :visibility])
    |> validate_required([:organization_id, :name, :slug, :visibility, :is_default])
    |> validate_length(:name, max: 160)
    |> validate_length(:slug, max: 100)
    |> validate_format(:slug, ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/)
    |> validate_inclusion(:visibility, @visibilities)
    |> validate_default_visibility()
    |> unique_constraint([:organization_id, :slug])
    |> unique_constraint(:organization_id, name: :workspaces_one_default_per_organization)
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:created_by_id)
  end

  defp validate_default_visibility(changeset) do
    if get_field(changeset, :is_default) && get_field(changeset, :visibility) != "open" do
      add_error(changeset, :visibility, "must be open for the default workspace")
    else
      changeset
    end
  end
end
