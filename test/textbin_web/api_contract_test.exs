defmodule TextbinWeb.ApiContractTest do
  @moduledoc """
  Keeps `TextbinWeb.ApiSpec` and the server in step: the document covers
  every API route and the exported `priv/openapi.json` is current.
  """

  use ExUnit.Case, async: true

  alias OpenApiSpex.Reference
  alias TextbinWeb.ApiSpec

  @exported_spec Path.expand("../../priv/openapi.json", __DIR__)

  describe "the document" do
    test "documents every API route and nothing else" do
      routed =
        for route <- Phoenix.Router.routes(TextbinWeb.Router),
            String.starts_with?(route.path, "/api/") or route.path == "/pastes/:id/raw",
            into: MapSet.new(),
            do: {route.verb, Regex.replace(~r/:(\w+)/, route.path, "{\\1}")}

      documented =
        MapSet.new(ApiSpec.operations(), fn {method, path, _operation} -> {method, path} end)

      assert MapSet.difference(routed, documented) == MapSet.new(),
             "routes missing from TextbinWeb.ApiSpec"

      assert MapSet.difference(documented, routed) == MapSet.new(),
             "operations in TextbinWeb.ApiSpec with no route"
    end

    test "gives each operation a unique id and resolves every schema reference" do
      operation_ids =
        for {_method, _path, operation} <- ApiSpec.operations(), do: operation.operationId

      assert Enum.uniq(operation_ids) == operation_ids

      spec = ApiSpec.spec()
      known = Map.keys(spec.components.schemas)

      for ref <- references(spec) do
        assert "#/components/schemas/" <> title = ref
        assert title in known, "#{ref} does not resolve"
      end
    end

    test "priv/openapi.json is the exported spec" do
      current =
        ApiSpec.spec() |> OpenApiSpex.OpenApi.to_map() |> Jason.encode!() |> Jason.decode!()

      assert File.exists?(@exported_spec), "run `mix openapi.export` to create priv/openapi.json"

      assert Jason.decode!(File.read!(@exported_spec)) == current,
             "priv/openapi.json is out of date; run `mix openapi.export`"
    end
  end

  defp references(%Reference{"$ref": ref}), do: [ref]
  defp references(%_struct{} = struct), do: struct |> Map.from_struct() |> references()
  defp references(map) when is_map(map), do: Enum.flat_map(Map.values(map), &references/1)
  defp references(list) when is_list(list), do: Enum.flat_map(list, &references/1)
  defp references(_value), do: []
end
