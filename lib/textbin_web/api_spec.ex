defmodule TextbinWeb.ApiSpec do
  @moduledoc """
  The OpenAPI document for the v1 API and the raw paste endpoint.

  Each operation is declared next to its action with
  `OpenApiSpex.ControllerSpecs`, so a change to an endpoint and its contract
  land in the same place; this module assembles them from the router and
  adds the shared schemas and security. Request validation and the test-time
  response check both read the same operations, and `priv/openapi.json` is
  the exported copy, kept current by a test.
  """

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Components, Info, OpenApi, Operation, Paths, SecurityScheme, Server}

  alias TextbinWeb.ApiSpec.Schemas

  @impl OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Textbin API",
        version: "1",
        description:
          "Authenticate with `Authorization: Bearer <token>`. Create a token with POST /api/v1/auth/tokens or in account settings."
      },
      servers: [%Server{url: "/"}],
      security: [%{"bearer" => []}],
      components: %Components{
        schemas: Schemas.all(),
        securitySchemes: %{
          "bearer" => %SecurityScheme{type: "http", scheme: "bearer"}
        }
      },
      paths: Paths.from_router(TextbinWeb.Router)
    }
  end

  @doc "Every operation in the document as `{method, path, operation}`."
  def operations do
    for {path, item} <- spec().paths,
        {method, %Operation{} = operation} <- Map.from_struct(item),
        method in [:get, :post, :put, :patch, :delete],
        do: {method, path, operation}
  end
end
