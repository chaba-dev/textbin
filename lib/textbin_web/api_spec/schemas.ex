defmodule TextbinWeb.ApiSpec.Schemas do
  @moduledoc """
  Response and request schemas for the v1 API.

  Response objects set `additionalProperties: false` on purpose: the contract
  tests cast real responses against these schemas, so a field added to a JSON
  view without being documented here fails the build instead of drifting
  silently. Request objects stay open because the server ignores unknown
  fields.
  """

  alias OpenApiSpex.{Reference, Schema}

  @uuid %Schema{type: :string, format: :uuid}
  @timestamp %Schema{type: :string, format: :"date-time"}
  @nullable_timestamp %Schema{type: :string, format: :"date-time", nullable: true}
  @expiry_examples ["10m", "1h", "6h", "12h", "1d", "7d", "30d", "never"]

  @doc "Every named schema, keyed by the title it is referenced by."
  def all do
    [
      error(),
      validation_error(),
      create_token_request(),
      identity(),
      identity_response(),
      created_token_response(),
      organization(),
      organization_list(),
      workspace(),
      workspace_list(),
      audit_event(),
      audit_event_page(),
      workspace_recovery(),
      paste_metadata(),
      paste(),
      removed_paste(),
      paste_response(),
      paste_metadata_response(),
      paste_list(),
      removed_paste_list(),
      create_paste_request()
    ]
    |> Map.new(&{&1.title, &1})
  end

  def ref(title), do: %Reference{"$ref": "#/components/schemas/#{title}"}

  def error do
    object("Error", "A request the server could not complete.",
      errors:
        object(nil, nil, detail: %Schema{type: :string, description: "Human-readable reason"})
    )
  end

  def validation_error do
    %Schema{
      title: "ValidationError",
      description: "Rejected input, as messages keyed by field.",
      type: :object,
      required: [:errors],
      additionalProperties: false,
      properties: %{
        errors: %Schema{
          type: :object,
          additionalProperties: %Schema{type: :array, items: %Schema{type: :string}}
        }
      }
    }
  end

  def create_token_request do
    %Schema{
      title: "CreateTokenRequest",
      type: :object,
      required: [:email, :password],
      properties: %{
        email: %Schema{type: :string, format: :email},
        password: %Schema{type: :string, format: :password},
        name: %Schema{type: :string, description: "Defaults to \"Textbin CLI\""}
      }
    }
  end

  def identity do
    object("Identity", "The account and API token a request is authenticated as.",
      user: object(nil, nil, id: @uuid, email: %Schema{type: :string, format: :email}),
      token:
        object(nil, "The token's metadata. The secret is only returned once, on creation.",
          id: @uuid,
          name: %Schema{type: :string},
          inserted_at: @timestamp
        )
    )
  end

  def identity_response, do: object("IdentityResponse", nil, data: ref("Identity"))

  def created_token_response do
    identity = identity()

    object("CreatedTokenResponse", nil,
      data: %Schema{
        identity
        | title: nil,
          required: Enum.sort([:api_token | identity.required]),
          properties:
            Map.put(identity.properties, :api_token, %Schema{
              type: :string,
              description: "The bearer token. Store it now; it is not shown again."
            })
      }
    )
  end

  def organization do
    object("Organization", nil,
      id: @uuid,
      name: %Schema{type: :string},
      slug: %Schema{type: :string},
      kind: %Schema{type: :string, enum: ["personal", "team"]}
    )
  end

  def organization_list,
    do: object("OrganizationList", nil, data: %Schema{type: :array, items: ref("Organization")})

  def workspace do
    object("Workspace", nil,
      id: @uuid,
      organization_id: @uuid,
      name: %Schema{type: :string},
      slug: %Schema{type: :string},
      visibility: %Schema{
        type: :string,
        enum: ["open", "private"],
        description: "Who can join: open to anyone in the organization, or private (invite only)"
      },
      external_sharing_policy: %Schema{
        type: :string,
        enum: ["disabled", "unlisted", "public"],
        description:
          "Sharing outside the team: members only, members may share a link, or members may also publish"
      },
      is_default: %Schema{type: :boolean}
    )
  end

  def workspace_list do
    object("WorkspaceList", nil,
      data: %Schema{type: :array, items: ref("Workspace")},
      organization: ref("Organization")
    )
  end

  def audit_event do
    object("AuditEvent", nil,
      id: @uuid,
      actor_user_id: %Schema{type: :string, format: :uuid, nullable: true},
      action: %Schema{type: :string, example: "workspace.created"},
      target_type: %Schema{type: :string},
      target_id: %Schema{type: :string, format: :uuid, nullable: true},
      metadata: %Schema{type: :object, additionalProperties: true},
      inserted_at: @timestamp
    )
  end

  def audit_event_page do
    object("AuditEventPage", "Newest first. Pass next_cursor back as cursor for older events.",
      data: %Schema{type: :array, items: ref("AuditEvent")},
      next_cursor: %Schema{type: :string, nullable: true}
    )
  end

  def workspace_recovery do
    object("WorkspaceRecovery", nil,
      data:
        object(nil, nil,
          workspace_id: @uuid,
          user_id: @uuid,
          role: %Schema{type: :string, enum: ["owner", "member"]}
        )
    )
  end

  def paste_metadata do
    %Schema{
      title: "PasteMetadata",
      description: "A paste without its content.",
      type: :object,
      required: required(paste_metadata_properties()),
      additionalProperties: false,
      properties: paste_metadata_properties()
    }
  end

  def paste do
    properties =
      Map.merge(paste_metadata_properties(), %{
        data: %Schema{
          type: :string,
          nullable: true,
          description: "The content as text, or null when it is binary"
        },
        data_base64: %Schema{
          type: :string,
          format: :byte,
          description: "Present only for binary content"
        },
        data_encoding: %Schema{type: :string, enum: ["base64"]}
      })

    %Schema{
      title: "Paste",
      description: "A paste with its content.",
      type: :object,
      required: paste_metadata_properties() |> Map.put(:data, nil) |> required(),
      additionalProperties: false,
      properties: properties
    }
  end

  def removed_paste do
    properties =
      Map.merge(paste_metadata_properties(), %{
        removed_at: @timestamp,
        removal_reason: %Schema{
          type: :string,
          enum: ["deleted", "expired", "moderated", "purging"]
        },
        purge_after: %Schema{
          type: :string,
          format: :"date-time",
          description: "When the paste is deleted for good unless restored"
        }
      })

    %Schema{
      title: "RemovedPaste",
      description:
        "A deleted or expired paste that can still be restored. Content is never included.",
      type: :object,
      required: required(properties),
      additionalProperties: false,
      properties: properties
    }
  end

  def paste_response, do: object("PasteResponse", nil, data: ref("Paste"))

  def paste_metadata_response,
    do: object("PasteMetadataResponse", nil, data: ref("PasteMetadata"))

  def paste_list,
    do: object("PasteList", nil, data: %Schema{type: :array, items: ref("Paste")})

  def removed_paste_list,
    do: object("RemovedPasteList", nil, data: %Schema{type: :array, items: ref("RemovedPaste")})

  def create_paste_request do
    %Schema{
      title: "CreatePasteRequest",
      description:
        "JSON form of a new paste. To upload raw bytes instead, send them as the request body with any other content type and pass these fields as query parameters.",
      type: :object,
      required: [:data],
      properties:
        Map.merge(create_paste_fields(), %{
          data: %Schema{type: :string, description: "The paste content"}
        })
    }
  end

  @doc "Optional paste fields, accepted in a JSON body or as query parameters."
  def create_paste_fields do
    %{
      title: %Schema{type: :string, description: "Taken from the first line when blank"},
      reference_url: %Schema{
        type: :string,
        format: :uri,
        description: "A ticket or incident link"
      },
      content_type: %Schema{type: :string, example: "text/plain"},
      syntax_highlight: %Schema{type: :string, example: "elixir"},
      audience: %Schema{
        type: :string,
        enum: ["workspace", "unlisted", "public"],
        description:
          "Who can see this: the workspace, anyone with the link, or the public. Limited by the workspace's external sharing policy."
      },
      visibility: %Schema{
        type: :string,
        enum: ["private", "unlisted", "public"],
        deprecated: true,
        description: "Use audience. private means workspace."
      },
      expires_in: %Schema{
        type: :string,
        description: "One of #{Enum.join(@expiry_examples, ", ")}",
        example: "1d"
      },
      ttl: %Schema{type: :string, deprecated: true, description: "Use expires_in."}
    }
  end

  defp paste_metadata_properties do
    %{
      id: @uuid,
      url: %Schema{type: :string, format: :uri, description: "The page to share"},
      raw_url: %Schema{type: :string, format: :uri, description: "The exact stored bytes"},
      organization_id: @uuid,
      workspace_id: @uuid,
      title: %Schema{type: :string, nullable: true},
      reference_url: %Schema{type: :string, nullable: true},
      content_type: %Schema{type: :string},
      syntax_highlight: %Schema{type: :string},
      audience: %Schema{type: :string, enum: ["workspace", "unlisted", "public"]},
      visibility: %Schema{
        type: :string,
        enum: ["private", "unlisted", "public"],
        deprecated: true,
        description: "Use audience. private means workspace."
      },
      expires_at: @nullable_timestamp,
      inserted_at: @timestamp,
      updated_at: @timestamp
    }
  end

  # Map key order is not stable across OTP releases (atom-keyed maps stopped
  # iterating alphabetically in OTP 26), and the exported document must be
  # byte-for-byte the same wherever it is generated.
  defp required(properties), do: properties |> Map.keys() |> Enum.sort()

  # A closed object whose listed properties are all required.
  defp object(title, description, properties) do
    properties = Map.new(properties)

    %Schema{
      title: title,
      description: description,
      type: :object,
      required: required(properties),
      additionalProperties: false,
      properties: properties
    }
  end
end
