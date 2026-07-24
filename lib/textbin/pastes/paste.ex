defmodule Textbin.Pastes.Paste do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # Store timestamps at millisecond precision so API output and database values
  # stay stable across adapters and reloads.
  @timestamps_opts [type: :utc_datetime_usec, autogenerate: {__MODULE__, :utc_now_ms, []}]
  @ttl_presets %{
    "10m" => 10 * 60,
    "1h" => 60 * 60,
    "6h" => 6 * 60 * 60,
    "12h" => 12 * 60 * 60,
    "1d" => 24 * 60 * 60,
    "7d" => 7 * 24 * 60 * 60,
    "30d" => 30 * 24 * 60 * 60
  }

  schema "pastes" do
    field :data, :string
    field :syntax_highlight, :string, default: "plain"
    field :expires_at, :utc_datetime_usec
    field :expires_in, :string, virtual: true

    belongs_to :user, Textbin.Accounts.User

    timestamps()
  end

  def changeset(paste, attrs) do
    paste
    |> cast(attrs, [:data, :syntax_highlight, :expires_in])
    |> put_expires_at(attrs)
    |> validate_required([:data, :syntax_highlight, :user_id])
    |> validate_expiration()
  end

  defp put_expires_at(changeset, attrs) do
    if !ttl_provided?(attrs) and get_field(changeset, :expires_at) do
      changeset
    else
      put_expires_at_change(changeset, attrs)
    end
  end

  defp put_expires_at_change(changeset, attrs) do
    case expires_at(attrs) do
      {:ok, expires_at} -> put_change(changeset, :expires_at, expires_at)
      :error -> put_change(changeset, :expires_at, utc_now_ms())
    end
  end

  defp expires_at(attrs) do
    case attrs |> ttl_value() |> ttl_seconds() do
      {:ok, nil} -> {:ok, nil}
      {:ok, ttl_seconds} -> {:ok, DateTime.add(utc_now_ms(), ttl_seconds, :second)}
      :error -> :error
    end
  end

  defp ttl_value(attrs) when is_map(attrs) do
    Map.get(attrs, "expires_in") || Map.get(attrs, :expires_in) || Map.get(attrs, "ttl") ||
      Map.get(attrs, :ttl)
  end

  defp ttl_value(_attrs), do: nil

  defp ttl_seconds(nil), do: {:ok, nil}

  defp ttl_seconds(value) when is_binary(value) do
    case String.trim(value) do
      "never" ->
        {:ok, nil}

      value ->
        case Map.fetch(@ttl_presets, value) do
          {:ok, ttl_seconds} -> {:ok, ttl_seconds}
          :error -> :error
        end
    end
  end

  defp ttl_seconds(_value), do: :error

  defp ttl_provided?(attrs) when is_map(attrs) do
    ttl_value(attrs) not in [nil, ""]
  end

  defp ttl_provided?(_attrs), do: false

  defp validate_expiration(changeset) do
    case get_field(changeset, :expires_at) do
      %DateTime{} = expires_at ->
        if DateTime.after?(expires_at, utc_now_ms()) do
          changeset
        else
          add_error(
            changeset,
            :expires_at,
            "must use one of: never, 10m, 1h, 6h, 12h, 1d, 7d, 30d"
          )
        end

      _expires_at ->
        changeset
    end
  end

  def utc_now_ms do
    # Ecto's :utc_datetime_usec type expects six-digit precision metadata even
    # when the value itself is intentionally millisecond-aligned.
    %{microsecond: {microsecond, 3}} =
      timestamp = DateTime.utc_now() |> DateTime.truncate(:millisecond)

    %{timestamp | microsecond: {microsecond, 6}}
  end
end
