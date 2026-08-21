---
rfc: 0006
title: Commercial and enterprise
status: Draft
---

# RFC 0006: Commercial and enterprise

## Goal

Add hosted commercial capabilities only after the stable API, administration,
and hosted-safety foundations exist.

## Billing and higher limits

Billing is organization-based. A subscription controls entitlements such as
paste size, storage, retention, member count, and API-token count. Provider
webhooks are authenticated, idempotent, persisted before processing, and safe
to replay. Billing status never becomes an authorization substitute for
organization roles.

Downgrades do not delete content immediately. They block new over-limit actions
and provide a documented grace policy. Exact plans, prices, provider, tax
handling, grace periods, and quotas require a separate commercial decision.

## Enterprise identity

OIDC is implemented before SAML unless customer demand changes the order.
Domain discovery does not automatically merge accounts. Linking an external
identity requires authenticated proof and preserves a recovery path.

SCIM provisioning is organization-scoped, uses independently revocable bearer
credentials, and handles retries idempotently. Deprovisioning removes managed
organization access without deleting the underlying user or unrelated
memberships.

## Custom domains

Custom domains require verified DNS control, certificate issuance and renewal,
collision prevention, and canonical URL behavior. Authentication cookies remain
bound to the primary Textbin domain unless a dedicated custom-domain auth model
is specified.

## Audit and compliance exports

Organization audit coverage expands to paste lifecycle, sharing-policy changes,
membership and invitation changes, token lifecycle, workspace settings, and
enterprise identity events. Reads of paste content are not logged by default;
enabling them requires a privacy and volume policy.

Exports are generated asynchronously, encrypted at rest, short-lived, and
available only to authorized organization owners. They include a manifest and
checksums and never include credential material.

## Support and SLA packaging

Support tiers define channels, support hours, severity levels, response targets,
service exclusions, and status-communication behavior. Availability promises
are not published until monitoring and incident response can measure them.

## Acceptance criteria

- [ ] Entitlements are deterministic, auditable, and resilient to duplicated or
  reordered billing webhooks.
- [ ] Billing failures cannot grant authority or expose another organization's data.
- [ ] OIDC, SAML, and SCIM identities are tenant-scoped and cannot be claimed by an
  unrelated organization.
- [ ] Custom-domain verification and certificate renewal fail closed.
- [ ] Exports are authorized at download time and expire automatically.
- [ ] Published SLA measurements match the actual monitoring definition.
