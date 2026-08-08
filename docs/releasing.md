# Releasing Textbin

Textbin uses a reviewable release-PR flow. Conventional PR titles determine the
next semantic version and release notes; maintainers do not create release tags
or GitHub Releases manually.

## One-time repository setup

Create and install a GitHub App for this repository with these repository
permissions:

- Contents: read and write
- Pull requests: read and write

Create a GitHub Actions environment named `RELEASE`, then store the App
credentials as secrets in that environment:

```text
RELEASE_APP_ID
RELEASE_APP_PRIVATE_KEY
```

The release workflows explicitly target the `RELEASE` environment so GitHub
makes these environment-scoped secrets available to their jobs. Environment
protection rules, if configured, also apply to release preparation and
publication.

The automation intentionally uses an installation token instead of
`GITHUB_TOKEN`. Branch and tag pushes made with `GITHUB_TOKEN` do not trigger the
downstream workflows required to tag, create a GitHub Release, and publish the
container.

Protect `main` and require the Conventional Commits title check. If tag or
branch rules restrict automation, allow the installed release App to update
`release/next` and create `v*` tags.

After the first container publication, make the `chaba2/textbin` package public
in GitHub's package settings as described in the self-hosting guide.

## Automated flow

Every ordinary push to `main` refreshes one release PR from `release/next`.
The workflow:

1. finds the latest reachable `v*` tag and commits since that tag;
2. asks git-cliff to choose the next version from Conventional Commits;
3. keeps the Phoenix and Cargo workspace versions synchronized;
4. regenerates `CHANGELOG.md` and a release-notes preview;
5. force-updates `release/next` with lease protection; and
6. creates or updates the release PR title, notes, commit count, and comparison
   from the previous tag to the current `main` commit.

Before the first tag, the existing synchronized project version is used. After
that, git-cliff calculates the next stable semantic version. The release PR can
also be refreshed manually with the **Prepare release PR** workflow.

Review the generated version, changelog, notes, and comparison. Do not manually
edit the generated release branch; the next `main` push replaces it.

The release PR also builds the production CLI and OTP release. Its release smoke
test reads the version embedded in each artifact and requires both versions to
match the version in the release PR title. Require the **Verify CLI and server
release versions** check in the `main` branch ruleset so a failed artifact check
cannot be bypassed accidentally.

Merging the internal `release/next` PR starts a privileged but narrowly gated
workflow. It verifies that:

- the PR was merged from this repository rather than a fork;
- its title is exactly `chore(release): vMAJOR.MINOR.PATCH`;
- `mix.exs` and `Cargo.toml` contain the same version; and
- that version matches the requested tag.

It then creates the tag at the actual PR merge commit. An existing tag is a
clean no-op.

The App-authenticated tag push generates the final Conventional Commit notes,
adds a link comparing the previous and current tags, and creates the GitHub
Release. Creating the Release triggers the GHCR workflow, which publishes the
multi-architecture image and provenance attestation.

```text
main changes
    -> release/next PR
    -> vMAJOR.MINOR.PATCH tag
    -> GitHub Release with notes and tag comparison
    -> ghcr.io/chaba2/textbin
```

## Local preview

The Nix development shell includes git-cliff. Preview the complete changelog or
the next bump with:

```bash
make changelog
git cliff --bumped-version
```

`make changelog` rewrites `CHANGELOG.md`; discard that local preview if it was
not intended as a release change.
