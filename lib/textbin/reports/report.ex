defmodule Textbin.Reports.Report do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @categories ["spam", "malware", "harassment", "copyright", "other"]
  @statuses ["open", "actioned", "dismissed"]

  schema "reports" do
    field :paste_id, :binary_id
    field :reporter_user_id, :binary_id
    field :category, :string
    field :notes, :string
    field :status, :string, default: "open"
    field :resolution_reason, :string
    field :resolved_by_user_id, :binary_id
    field :resolved_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def submission_changeset(report, attrs) do
    report
    |> cast(attrs, [:category, :notes])
    |> validate_required([:paste_id, :reporter_user_id, :category, :status])
    |> validate_inclusion(:category, @categories)
    |> validate_length(:notes, max: 1_000)
    |> unique_constraint([:paste_id, :reporter_user_id],
      name: :reports_one_open_per_reporter_index,
      message: "has already been reported"
    )
  end

  def categories, do: @categories
  def statuses, do: @statuses
end
