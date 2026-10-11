defmodule TextbinWeb.ApiDocs do
  @moduledoc """
  Building blocks for the `operation` specs that API controllers declare
  next to their actions with `OpenApiSpex.ControllerSpecs`.

  Specs are evaluated when the controller compiles, so they cannot call
  functions of the controller itself; the shared pieces live here instead.
  Request and response schemas live in `TextbinWeb.ApiSpec.Schemas` and are
  referenced by title.
  """

  alias OpenApiSpex.{MediaType, RequestBody, Response, Schema}
  alias TextbinWeb.ApiSpec.Schemas

  @doc "A JSON response whose body is the named schema."
  def response(description, title), do: {description, "application/json", Schemas.ref(title)}

  def error(description), do: response(description, "Error")

  def unauthorized, do: error("Missing, invalid or revoked API token")

  @doc "The 422 every operation with parameters or a body can return."
  def invalid_request,
    do: response("The parameters or body do not match this operation", "ValidationError")

  def no_content(description), do: %Response{description: description}

  def uuid_path(description) do
    [
      in: :path,
      required: true,
      description: description,
      schema: %Schema{type: :string, format: :uuid}
    ]
  end

  def query(schema, description),
    do: [in: :query, required: false, description: description || "", schema: schema]

  def json_body(title) do
    %RequestBody{
      required: true,
      content: %{"application/json" => %MediaType{schema: Schemas.ref(title)}}
    }
  end

  @doc """
  Adds the responses every authenticated, validated operation shares: a
  missing token, and a request that does not match the operation. An
  operation's own wording for a status wins.
  """
  def with_common_errors(responses) do
    Map.merge(%{401 => unauthorized(), 422 => invalid_request()}, responses)
  end

  # Paste operations share these. The personal workspace always exists, so
  # the "Workspace not found" 404 is added by in_workspace/1 only.
  def with_scope_errors(responses), do: with_common_errors(responses)

  @doc "The optional paste fields as query parameters, for raw-body uploads."
  def paste_field_parameters do
    for {name, schema} <- Enum.sort(Schemas.create_paste_fields()),
        do: {name, query(schema, schema.description)}
  end

  def create_paste_body do
    %RequestBody{
      required: true,
      content: %{
        "application/json" => %MediaType{schema: Schemas.ref("CreatePasteRequest")},
        "*/*" => %MediaType{schema: %Schema{type: :string, format: :binary}}
      }
    }
  end

  @doc """
  The workspace-scoped variant of a personal-workspace paste operation: the
  same behaviour under /workspaces/{workspace_id}, with its own operation id.
  """
  def in_workspace(spec) do
    workspace_id = {:workspace_id, uuid_path("Workspace id")}

    spec
    |> Keyword.update(:parameters, [workspace_id], &[workspace_id | &1])
    |> Keyword.update!(:responses, &Map.put_new(&1, 404, error("Workspace not found")))
    |> Keyword.update!(:operation_id, &(&1 <> "InWorkspace"))
    |> Keyword.update!(:summary, &String.replace(&1, "your personal workspace", "a workspace"))
  end
end
