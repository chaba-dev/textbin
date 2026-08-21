# Textbin product specifications

These documents are draft product and engineering contracts for work that has
not yet been scheduled. They define intended outcomes, authorization boundaries,
and acceptance criteria without committing to delivery order.

| Specification | Covers |
|---|---|
| [Administration](administration.md) | Platform administrators, authorization, bootstrap, moderation, and internal views |
| [Self-hosting documentation](self-hosting-documentation.md) | Operator documentation for deploying and recovering the portable image |
| [Paste discovery and API contract](paste-discovery-and-api.md) | Metadata, viewer polish, filters, search, JSON output, OpenAPI, and SDKs |
| [Hosted safety and operations](hosted-safety-and-operations.md) | Limits, rate limiting, abuse controls, telemetry, tracing, and backups |
| [Workspace collaboration](workspace-collaboration.md) | Invitations, defaults, workspace tokens, and CLI workflows |
| [Commercial and enterprise](commercial-and-enterprise.md) | Billing, paid limits, SSO, SCIM, domains, compliance, and support |
| [Advanced developer workflows](advanced-developer-workflows.md) | Redaction, CI helpers, bundles, diffs, migration, encryption, and integrations |

## Shared principles

- Context functions enforce authorization; hiding a control in the UI is never
  an authorization boundary.
- Browser routes use the existing authenticated router scope when login is
  required. API routes use bearer authentication and the same context policies.
- Every collection is scoped in the database query rather than fetched and
  filtered afterward.
- Security-sensitive mutations are auditable and require recent
  reauthentication where stolen-session risk warrants it.
- Public API changes are specified in OpenAPI before being treated as stable.
- Features should work for both hosted and self-hosted installations unless a
  specification explicitly identifies them as hosted-only.
