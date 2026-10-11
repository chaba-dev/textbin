defmodule TextbinWeb.ApiContract do
  @moduledoc """
  Checks a real API response against the operation it claims to implement in
  `TextbinWeb.ApiSpec`: the status must be documented for that operation, and
  a JSON body must cast against its schema. Response schemas are closed, so an
  undocumented field fails as surely as a missing one.
  """

  import ExUnit.Assertions

  alias OpenApiSpex.{MediaType, Response}
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
