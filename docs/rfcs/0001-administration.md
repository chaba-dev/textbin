---
rfc: 0001
title: Administration
status: Draft
---

# RFC 0001: Administration

## Goal

Give trusted operators a narrowly authorized panel for operating the Textbin
installation without conflating platform authority with organization or
workspace roles.

## Roles and authority

Textbin adds a platform-level `admin` role. It is independent of organization
`owner` and `admin` memberships:

- Organization roles grant authority only inside that organization.
- Platform administrators can operate the installation across organizations.
- A platform administrator receives no implicit organization membership and
  must not appear as a workspace collaborator.
- Ordinary users have no platform role. Absence of the role is the default.

Platform authority is stored on the user account or in a dedicated platform
role relation with a database constraint over supported values. Authorization
must not depend on email addresses, configuration allowlists, or UI state.

## Authentication and authorization

The admin LiveViews belong inside the existing
`live_session :require_authenticated_user` and
`[:browser, :require_authenticated_user]` pipeline because every admin route
requires a current user. A platform-admin `on_mount` hook then rejects
non-admins before mounting the page.

Context modules repeat the platform-admin check for every read and mutation so
they remain safe when called by a controller, release task, or future API. A
denied browser request behaves as not found unless showing an explicit forbidden
response is operationally useful; APIs return `403` after authentication.

Destructive and privilege-changing actions require recent reauthentication.
Administrative sessions use the normal session lifetime; there is no separate
permanent admin session or impersonation feature.

## Initial administrator bootstrap

The release exposes an idempotent RPC-compatible function that grants the
platform-admin role to an existing, confirmed user identified by normalized
email. Operators invoke it through the release binary. It must:

1. fail if the user does not exist or is not confirmed;
2. lock and update the selected account transactionally;
3. report whether authority was granted or already present; and
4. append an immutable platform audit event naming the actor as the bootstrap
   mechanism.

The function does not accept or print passwords. Registration and confirmation
remain the normal account-creation path. Revoking the final platform admin is
rejected unless a replacement is granted in the same operation.

## Panel scope

The first admin panel provides:

- installation totals and recent operational failures;
- user lookup by exact email or ID and account status;
- organization and workspace lookup with membership summaries;
- recent and largest paste metadata, without rendering content by default;
- abuse reports and their resolution state;
- administrative paste deletion;
- account suspension and restoration; and
- platform administrator grant and revocation.

Viewing paste content, impersonating users, editing user content, changing
organization ownership, and reading bearer tokens are not part of the first
version.

## Audit requirements

Every administrative mutation records an append-only platform audit event with
the actor, action, target type and ID, timestamp, request ID when available, and
non-secret structured metadata. Bootstrap events identify the release command
rather than inventing a user actor. Audit records never contain paste content,
passwords, session tokens, API tokens, or storage credentials.

Only platform administrators can read platform audit events. Organization audit
events remain governed by organization authorization and are not a substitute
for the platform log.

## Acceptance criteria

- [ ] A non-admin cannot mount an admin route or obtain admin data by calling a
  context function directly.
- [ ] Organization owners and admins have no platform authority unless separately
  granted it.
- [ ] An operator can grant the first platform administrator from a release without
  manipulating the database manually.
- [ ] Every privilege change, suspension, restoration, and administrative deletion
  is audited.
- [ ] Concurrent attempts cannot remove the final platform administrator.
- [ ] Admin list queries are paginated, scoped in SQL, and do not load paste bodies.
- [ ] Authorization, final-admin concurrency, reauthentication, and audit behavior
  have context and LiveView tests.
