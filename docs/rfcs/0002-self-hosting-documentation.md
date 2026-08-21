---
rfc: 0002
title: Self-hosting documentation
status: Draft
---

# RFC 0002: Self-hosting documentation

## Goal

Document the portable production image well enough that an operator can deploy,
upgrade, back up, restore, and troubleshoot Textbin on their chosen container
platform without requiring Phoenix knowledge.

## Product boundary

Textbin publishes an OCI image and documents its runtime contract. The project
does not maintain production Docker Compose, Kubernetes, Terraform, Helm, or
cloud-provider deployment artifacts. Any snippets are illustrative and must not
be represented as production-ready stacks.

The repository's Compose configuration may continue to support local
development dependencies. It is not a supported self-hosted topology.

## Required documentation

The self-hosting guide covers:

- supported image tags, architectures, digest pinning, and non-root UID/GID;
- required and optional environment variables with secure example generation;
- PostgreSQL version expectations, connection sizing, migrations, and health;
- local and S3-compatible object storage, permissions, persistence, and
  connectivity verification;
- temporary upload space sizing and lifecycle;
- reverse-proxy and direct-TLS topologies, forwarded headers, and health checks;
- first-user registration and platform-admin bootstrap;
- rolling and single-node upgrades, rollback constraints, and migration order;
- coordinated PostgreSQL and blob backup/restore order;
- a restore drill with integrity checks rather than backup creation alone; and
- common startup failures and diagnostics that do not expose secrets.

## Examples

Examples use placeholders, least-privilege credentials, exact image versions,
and explicit persistent mounts. They must not contain reusable passwords or
suggest exposing PostgreSQL or object storage publicly.

A minimal example may show one application process and its dependencies, but it
must state that availability, TLS, secret management, monitoring, and backup
scheduling are operator responsibilities.

## Acceptance criteria

- [ ] A fresh operator can identify every required external dependency and durable
  path from the guide alone.
- [ ] Local-storage and S3-compatible deployments each have a complete configuration
  example and verification procedure.
- [ ] The documented migration, admin-bootstrap, backup, restore, and upgrade
  commands execute against the published release image.
- [ ] Documentation clearly separates supported runtime contracts from illustrative
  orchestration examples.
- [ ] A restore drill verifies both metadata and external paste content.
