# Textbin RFCs

RFCs are numbered product and engineering contracts. A Draft RFC describes a
proposal; it does not commit the project to delivery or delivery order.

| RFC | Covers |
|---|---|
| [0001: Administration](0001-administration.md) | Platform administrators, authorization, bootstrap, moderation, and internal views |
| [0002: Self-hosting documentation](0002-self-hosting-documentation.md) | Operator documentation for deploying and recovering the portable image |
| [0003: Paste discovery and API contract](0003-paste-discovery-and-api.md) | Metadata, viewer polish, filters, search, JSON output, OpenAPI, and SDKs |
| [0004: Hosted safety and operations](0004-hosted-safety-and-operations.md) | Limits, rate limiting, abuse controls, telemetry, tracing, and backups |
| [0005: Workspace collaboration](0005-workspace-collaboration.md) | Invitations, defaults, workspace tokens, and CLI workflows |
| [0006: Advanced developer workflows](0006-advanced-developer-workflows.md) | Redaction, CI helpers, bundles, diffs, migration, encryption, and integrations |

Run `./scripts/check-rfc-status.sh` to validate RFC numbering, metadata, status,
and acceptance-checklist progress. Supported statuses are `Draft`, `Accepted`,
`Active`, `Paused`, `Done`, `Rejected`, and `Superseded`.

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
