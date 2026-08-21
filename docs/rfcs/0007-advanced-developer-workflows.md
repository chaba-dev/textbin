---
rfc: 0007
title: Advanced developer workflows
status: Draft
---

# RFC 0007: Advanced developer workflows

## Goal

Add higher-level debugging workflows without weakening the core guarantees for
content integrity, authorization, predictable CLI output, and portability.

## Secret scanning and redaction

`scan` reports likely secrets without uploading. `--redact-secrets` applies a
versioned built-in rule set locally before upload; custom redaction expressions
are explicit and bounded against pathological runtime. Findings and redacted
values are never sent as telemetry.

Redaction is best-effort and must not claim that content is secret-free. JSON
output identifies rule names and locations without printing matched secret
values.

## CI helpers

CI mode is non-interactive, supports token environment overrides, emits stable
JSON, and returns documented exit codes. Metadata can capture provider and run
identifiers as ordinary bounded fields without granting those values trust.

## Multi-file bundles

A bundle has a manifest and multiple named entries. Paths are normalized,
relative, unique, and protected against traversal. Size, file-count, and
compression-expansion limits apply to the complete bundle. Authorization and
expiration apply to the bundle as one object.

## Diff support

Diff accepts two authorized text inputs, detects binary content, and enforces
size and compute limits. Server-side diff endpoints do not disclose whether an
unauthorized comparison target exists. Local-versus-remote comparisons may run
entirely in the CLI.

## Import, export, and migration

Exports use a versioned manifest, checksums, and streaming content files.
Imports validate the complete manifest and report conflicts before mutation.
Hosted-to-self-hosted migration composes export and import, checkpoints
progress, and is safe to resume without duplicating pastes.

Workspace exports require workspace-owner authorization. Platform-wide export
is an operator recovery tool, not an admin-panel convenience action.

## Client-side encryption

Encryption occurs before upload using a versioned, authenticated-encryption
envelope. Servers store ciphertext and minimal algorithm metadata and cannot
preview, highlight, scan, search, redact, or recover encrypted content. Keys are
never placed in normal URL query parameters, logs, API payload metadata, or
server storage.

Key derivation, recipient sharing, recovery, browser decryption, and URL-fragment
key UX require a dedicated cryptographic design review before implementation.

## Local integrations

Git, Docker, Kubernetes, and journal integrations are thin CLI adapters over
existing commands. They do not shell-expand user input, silently elevate
privileges, or add service-specific server APIs. Each helper shows or documents
the source command and preserves raw bytes until the upload boundary.

## Acceptance criteria

- [ ] Redaction tests include false positives, encoded secrets, large input, and
  adversarial custom expressions.
- [ ] CI behavior is deterministic without a TTY and never prints tokens.
- [ ] Bundles reject traversal, duplicate paths, archive bombs, and over-limit
  manifests before finalization.
- [ ] Diff authorization and resource limits are enforced server-side.
- [ ] Interrupted migration resumes without duplicate content.
- [ ] Client-side encryption ships only after its envelope and key-sharing model
  receive an explicit security review.
- [ ] Integration helpers introduce no new server-side trust boundary.
