# Hosted safety and operations specification

## Goal

Protect a public Textbin installation from accidental overload and abuse while
providing enough telemetry and recovery procedures to operate it safely.

## Upload limits

Limits are evaluated for the authenticated user, API token, source address, and
workspace as applicable. The effective paste-size and expiration limits come
from the most specific entitled scope. A request cannot bypass a workspace
limit by selecting a different client or content encoding.

Guest, free authenticated, and paid limits are configuration or entitlement
data rather than conditionals spread across controllers.

## Rate limiting

Initial rate limits cover authentication attempts, token creation, paste
creation, raw reads, and expensive search operations. Keys include normalized
client address, user ID, token ID, and workspace ID where available.

Client addresses are trusted only through explicitly configured proxy hops.
Production deployments with multiple application replicas use a shared limiter;
an in-memory limiter is acceptable only for documented single-node operation.
Responses use `429`, include `Retry-After`, and do not disclose whether an
account exists.

## Abuse controls and reports

Users can report public or unlisted pastes with a reason category and optional
notes. Reports enter an admin queue with open, actioned, and dismissed states.
Platform admins can remove a paste or suspend an account; both actions require a
reason and create platform audit events.

Private content is not proactively inspected. Automated blocked-content rules,
if introduced, operate on documented signals and retain only the minimum data
needed for enforcement. Shared unlisted pages use `noindex`; private pages are
never indexable.

## Structured logs, metrics, and tracing

Structured request and job logs include request ID, route, status, duration,
error class, storage backend, and relevant non-secret entity IDs. They never
include paste bodies, credentials, authorization headers, or raw session data.

Metrics cover request and upload counts, size and duration histograms, storage
and database errors, rate-limit decisions, report actions, and expiration-job
outcomes. Labels must have bounded cardinality; user, paste, token, request, and
IP values belong in logs, not metric labels.

Tracing is optional and disabled by default. When enabled, trace propagation and
sampling are configurable and spans follow the same content-redaction rules.

## Hosted backups

Hosted environments automate encrypted PostgreSQL and blob backups, record
their completion, and alert on missed schedules. Restore drills run on an
isolated environment and verify metadata-to-blob checksums. Recovery point and
recovery time objectives must be selected before the schedule and retention
policy can be finalized.

## Acceptance criteria

- Limits are enforced consistently across browser, raw API, JSON API, and CLI
  traffic.
- Tests cover proxy trust, distributed-limit behavior, retry headers, and key
  isolation.
- Reports can be submitted without exposing reporter identity publicly and can
  be resolved only by platform admins.
- Logs and traces pass tests that reject known secret and content fields.
- Metrics avoid unbounded labels and expose background cleanup failures.
- A documented hosted restore drill proves both database and blob recovery.
