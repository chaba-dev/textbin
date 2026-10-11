defmodule TextbinWeb.ApiContract do
  @moduledoc """
  Checks a real API response against the operation it claims to implement in
  `TextbinWeb.ApiSpec`: the status must be documented for that operation, and
  a JSON body must validate without type coercion. Response schemas are closed, so an
  undocumented field fails as surely as a missing one.
  """

  import ExUnit.Assertions

  alias OpenApiSpex.{MediaType, Reference, Response, Schema}
  alias TextbinWeb.ApiSpec

  def assert_api_response(%Plug.Conn{} = conn, operation_id) do
    spec = spec()
    operation = operation!(operation_id)

    response =
      Map.get(operation.responses, conn.status) ||
        flunk(
          "#{operation_id} returned #{conn.status}, which the spec does not document " <>
            "(documented: #{operation.responses |> Map.keys() |> Enum.sort() |> inspect()})"
        )

    case response do
      %Response{content: %{"application/json" => %MediaType{schema: schema}}} ->
        body = Jason.decode!(conn.resp_body)

        # Casting enforces closed objects and formats but accepts quoted
        # booleans/numbers. Validate the original wire types first; this API
        # expects property keys to match the decoded JSON's string keys.
        case Schema.validate(json_keys(schema), body, json_keys(spec.components.schemas)) do
          :ok -> :ok
          {:error, detail} -> flunk("#{operation_id} #{conn.status}: #{detail}")
        end

        case OpenApiSpex.cast_value(body, schema, spec) do
          {:ok, _value} ->
            :ok

          {:error, errors} ->
            details = Enum.map_join(errors, "\n", &"  #{&1}")

            flunk(
              "#{operation_id} #{conn.status} response does not match the spec:\n#{details}\n\n" <>
                "Body: #{conn.resp_body}"
            )
        end

      %Response{content: nil} ->
        assert conn.resp_body == "", "#{operation_id} #{conn.status} should have no body"

      %Response{} ->
        :ok
    end

    conn
  end

  defp json_keys(%Schema{} = schema) do
    normalized = schema |> Map.from_struct() |> json_keys() |> then(&struct!(Schema, &1))

    %{
      normalized
      | properties:
          Map.new(normalized.properties || %{}, fn {key, value} -> {to_string(key), value} end),
        required: Enum.map(normalized.required || [], &to_string/1)
    }
  end

  defp json_keys(%Reference{} = reference), do: reference

  defp json_keys(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, json_keys(value)} end)

  defp json_keys(list) when is_list(list), do: Enum.map(list, &json_keys/1)
  defp json_keys(value), do: value

  defp operation!(operation_id) do
    Enum.find_value(ApiSpec.operations(), fn {_method, _path, operation} ->
      operation.operationId == operation_id && operation
    end) || flunk("No operation #{operation_id} in TextbinWeb.ApiSpec")
  end

  # Building the spec is pure but not free; every assertion shares one copy.
  defp spec do
    case :persistent_term.get({__MODULE__, :spec}, nil) do
      nil ->
        spec = ApiSpec.spec()
        :persistent_term.put({__MODULE__, :spec}, spec)
        spec

      spec ->
        spec
    end
  end
end
