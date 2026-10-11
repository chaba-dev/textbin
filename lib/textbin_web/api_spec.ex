defmodule TextbinWeb.ApiSpec do
  @moduledoc """
  The OpenAPI document for the v1 API and the raw paste endpoint.

  The document is written out by hand rather than derived from controller
  annotations, so the whole public contract reads in one place. Two checks
  keep it honest: a test fails when a route under /api/v1 has no operation
  here (or the reverse), and contract tests cast real responses against the
  schemas. `priv/openapi.json` is the exported copy; CI regenerates it and
  fails if it differs, so a change to the contract shows up in review.
  """

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{
    Components,
    Info,
    MediaType,
    OpenApi,
    Operation,
    Parameter,
    PathItem,
    RequestBody,
    Response,
    Schema,
    SecurityScheme,
    Server
  }

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
      paths: paths()
    }
  end

  @doc "Every operation in the document as `{method, path, operation}`."
  def operations do
    for {path, item} <- spec().paths,
        {method, %Operation{} = operation} <- Map.from_struct(item),
        method in [:get, :post, :put, :patch, :delete],
        do: {method, path, operation}
  end

  defp paths do
    %{
      "/api/v1/auth/tokens" => %PathItem{post: create_token()},
      "/api/v1/me" => %PathItem{get: get_identity()},
      "/api/v1/me/token" => %PathItem{delete: revoke_current_token()},
      "/api/v1/organizations" => %PathItem{get: list_organizations()},
      "/api/v1/organizations/{id}/workspaces" => %PathItem{get: list_workspaces()},
      "/api/v1/organizations/{id}/audit-events" => %PathItem{get: list_audit_events()},
      "/api/v1/workspaces/{workspace_id}/recovery" => %PathItem{post: recover_workspace()},
      "/api/v1/pastes" => %PathItem{
        get: list_pastes(:personal),
        post: create_paste(:personal)
      },
      "/api/v1/pastes/{id}" => %PathItem{
        get: get_paste(:personal),
        delete: delete_paste(:personal)
      },
      "/api/v1/pastes/deleted" => %PathItem{get: list_removed_pastes(:personal)},
      "/api/v1/pastes/deleted/{id}" => %PathItem{delete: purge_paste(:personal)},
      "/api/v1/pastes/deleted/{id}/restore" => %PathItem{post: restore_paste(:personal)},
      "/api/v1/workspaces/{workspace_id}/pastes" => %PathItem{
        get: list_pastes(:workspace),
        post: create_paste(:workspace)
      },
      "/api/v1/workspaces/{workspace_id}/pastes/{id}" => %PathItem{
        get: get_paste(:workspace),
        delete: delete_paste(:workspace)
      },
      "/api/v1/workspaces/{workspace_id}/pastes/deleted" => %PathItem{
        get: list_removed_pastes(:workspace)
      },
      "/api/v1/workspaces/{workspace_id}/pastes/deleted/{id}" => %PathItem{
        delete: purge_paste(:workspace)
      },
      "/api/v1/workspaces/{workspace_id}/pastes/deleted/{id}/restore" => %PathItem{
        post: restore_paste(:workspace)
      },
      "/pastes/{id}/raw" => %PathItem{get: get_raw_paste()}
    }
  end

  ## Authentication

  defp create_token do
    %Operation{
      operationId: "createApiToken",
      tags: ["Authentication"],
      summary: "Create an API token with an email and password",
      security: [],
      requestBody: json_body("CreateTokenRequest"),
      responses: %{
        201 => json("The token and the account it belongs to", "CreatedTokenResponse"),
        400 => error("Email or password missing"),
        401 => error("Wrong email or password"),
        422 => error("The token could not be created")
      }
    }
  end

  defp get_identity do
    %Operation{
      operationId: "getIdentity",
      tags: ["Authentication"],
      summary: "Show the authenticated account and token",
      responses: %{200 => json("The current identity", "IdentityResponse"), 401 => unauthorized()}
    }
  end

  defp revoke_current_token do
    %Operation{
      operationId: "revokeCurrentToken",
      tags: ["Authentication"],
      summary: "Revoke the token used for this request",
      responses: %{204 => empty("Revoked, or already gone"), 401 => unauthorized()}
    }
  end

  ## Organizations and workspaces

  defp list_organizations do
    %Operation{
      operationId: "listOrganizations",
      tags: ["Organizations"],
      summary: "List the organizations you belong to",
      responses: %{200 => json("Organizations", "OrganizationList"), 401 => unauthorized()}
    }
  end

  defp list_workspaces do
    %Operation{
      operationId: "listOrganizationWorkspaces",
      tags: ["Organizations"],
      summary: "List workspaces you have joined or can join",
      parameters: [path(:id, "Organization id")],
      responses: %{
        200 => json("The organization and its workspaces", "WorkspaceList"),
        401 => unauthorized(),
        404 => error("Organization not found")
      }
    }
  end

  defp list_audit_events do
    %Operation{
      operationId: "listAuditEvents",
      tags: ["Organizations"],
      summary: "Page through an organization's audit log",
      parameters: [
        path(:id, "Organization id"),
        query(:limit, %Schema{type: :integer, minimum: 1}, "Events per page"),
        query(:cursor, %Schema{type: :string}, "next_cursor from the previous page")
      ],
      responses: %{
        200 => json("A page of audit events", "AuditEventPage"),
        401 => unauthorized(),
        404 => error("Organization not found, or you cannot read its audit log")
      }
    }
  end

  defp recover_workspace do
    %Operation{
      operationId: "recoverWorkspaceAccess",
      tags: ["Organizations"],
      summary: "Make yourself owner of a workspace in an organization you own",
      parameters: [path(:workspace_id, "Workspace id")],
      responses: %{
        201 => json("Your new membership", "WorkspaceRecovery"),
        401 => unauthorized(),
        404 => error("Workspace not found, or you cannot recover it")
      }
    }
  end

  ## Pastes

  # Every paste operation exists twice: once for the caller's personal
  # workspace, and once scoped to a workspace id.
  defp list_pastes(scope) do
    %Operation{
      operationId: operation_id("listPastes", scope),
      tags: ["Pastes"],
      summary: "List pastes in #{scope_name(scope)}",
      parameters: scope_parameters(scope),
      responses: scoped_responses(%{200 => json("Pastes, newest first", "PasteList")})
    }
  end

  defp create_paste(scope) do
    fields =
      for {name, schema} <- Enum.sort(Schemas.create_paste_fields()) do
        query(name, schema, schema.description)
      end

    %Operation{
      operationId: operation_id("createPaste", scope),
      tags: ["Pastes"],
      summary: "Create a paste in #{scope_name(scope)}",
      description:
        "Send JSON, or send the content itself as the request body (any other content type) with the fields as query parameters.",
      parameters: scope_parameters(scope) ++ fields,
      requestBody: %RequestBody{
        required: true,
        content: %{
          "application/json" => %MediaType{schema: Schemas.ref("CreatePasteRequest")},
          "*/*" => %MediaType{schema: %Schema{type: :string, format: :binary}}
        }
      },
      responses:
        scoped_responses(%{
          201 => json("The new paste, without its content", "PasteMetadataResponse"),
          400 => error("The request body could not be read"),
          413 => error("The content is larger than the server allows"),
          422 => json("Rejected fields", "ValidationError"),
          503 => error("Paste storage is temporarily unavailable")
        })
    }
  end

  defp get_paste(scope) do
    %Operation{
      operationId: operation_id("getPaste", scope),
      tags: ["Pastes"],
      summary: "Show a paste with its content",
      parameters: scope_parameters(scope) ++ [path(:id, "Paste id")],
      responses:
        scoped_responses(%{
          200 => json("The paste", "PasteResponse"),
          400 => error("The id is not a UUID"),
          404 => error("Paste or workspace not found")
        })
    }
  end

  defp delete_paste(scope) do
    %Operation{
      operationId: operation_id("deletePaste", scope),
      tags: ["Pastes"],
      summary: "Delete a paste; it stays restorable for the workspace's recovery window",
      parameters: scope_parameters(scope) ++ [path(:id, "Paste id")],
      responses:
        scoped_responses(%{
          204 => empty("Deleted, or nothing to delete"),
          503 => error("The deletion could not be completed")
        })
    }
  end

  defp list_removed_pastes(scope) do
    %Operation{
      operationId: operation_id("listRemovedPastes", scope),
      tags: ["Pastes"],
      summary: "List deleted and expired pastes that can still be restored",
      parameters: scope_parameters(scope),
      responses: scoped_responses(%{200 => json("Restorable pastes", "RemovedPasteList")})
    }
  end

  defp restore_paste(scope) do
    %Operation{
      operationId: operation_id("restorePaste", scope),
      tags: ["Pastes"],
      summary: "Restore a deleted or expired paste",
      parameters: scope_parameters(scope) ++ [path(:id, "Paste id")],
      responses:
        scoped_responses(%{
          200 => json("The restored paste, without its content", "PasteMetadataResponse"),
          400 => error("The id is not a UUID"),
          404 => error("No restorable paste you can manage has this id")
        })
    }
  end

  defp purge_paste(scope) do
    %Operation{
      operationId: operation_id("purgePaste", scope),
      tags: ["Pastes"],
      summary: "Delete a removed paste for good",
      parameters: scope_parameters(scope) ++ [path(:id, "Paste id")],
      responses:
        scoped_responses(%{
          204 => empty("Deleted for good"),
          400 => error("The id is not a UUID"),
          404 => error("No removed paste you can manage has this id"),
          503 => error("The stored content could not be deleted; try again")
        })
    }
  end

  defp get_raw_paste do
    %Operation{
      operationId: "getRawPaste",
      tags: ["Pastes"],
      summary: "Download a paste's exact stored bytes",
      description:
        "Uses the browser session or the paste's link, not a bearer token. Text that is safe to show inline is served with its content type; anything else downloads.",
      security: [],
      parameters: [
        path(:id, "Paste id"),
        query(:download, %Schema{type: :string}, "Present to download even safe text")
      ],
      responses: %{
        200 => %Response{
          description: "The stored bytes",
          content: %{"*/*" => %MediaType{schema: %Schema{type: :string, format: :binary}}}
        },
        404 => %Response{
          description: "Not found, or not shared with you",
          content: %{"text/plain" => %MediaType{schema: %Schema{type: :string}}}
        }
      }
    }
  end

  ## Helpers

  defp operation_id(name, :personal), do: name
  defp operation_id(name, :workspace), do: name <> "InWorkspace"

  defp scope_name(:personal), do: "your personal workspace"
  defp scope_name(:workspace), do: "a workspace"

  defp scope_parameters(:personal), do: []
  defp scope_parameters(:workspace), do: [path(:workspace_id, "Workspace id")]

  # Responses every paste operation shares; an operation's own 404 wording wins.
  defp scoped_responses(responses) do
    Map.merge(%{401 => unauthorized(), 404 => error("Workspace not found")}, responses)
  end

  defp path(name, description) do
    %Parameter{
      name: name,
      in: :path,
      required: true,
      description: description,
      schema: %Schema{type: :string, format: :uuid}
    }
  end

  defp query(name, schema, description) do
    %Parameter{name: name, in: :query, required: false, description: description, schema: schema}
  end

  defp json_body(title) do
    %RequestBody{
      required: true,
      content: %{"application/json" => %MediaType{schema: Schemas.ref(title)}}
    }
  end

  defp json(description, title) do
    %Response{
      description: description,
      content: %{"application/json" => %MediaType{schema: Schemas.ref(title)}}
    }
  end

  defp error(description), do: json(description, "Error")
  defp unauthorized, do: error("Missing, invalid or revoked API token")
  defp empty(description), do: %Response{description: description}
end
