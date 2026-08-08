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

Configure the `v*` tag rules as immutable: only the release App may create
release tags, and existing release tags must not be updated or deleted.

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

The release PR uses `dist` to build and execute the packaged CLI for Linux
x86-64 and ARM64, macOS Intel and Apple Silicon, and Windows x86-64. Separate
container checks build and execute the production server image for
`linux/amd64` and `linux/arm64`. Every artifact must report the version in the
release PR title. Require the stable aggregate checks **CLI release gate** and
**Server release gate** in the `main` branch ruleset; they cover every dynamic
platform job plus installer and checksum generation without making the ruleset
depend on matrix-generated check names.

Merging the internal `release/next` PR starts a privileged but narrowly gated
workflow. It verifies that:

- the PR was merged from this repository rather than a fork;
- its title is exactly `chore(release): vMAJOR.MINOR.PATCH`;
- `mix.exs` and `Cargo.toml` contain the same version; and
- that version matches the requested tag.

It then creates the tag at the actual PR merge commit. An existing tag is a
clean no-op.

The App-authenticated tag push rebuilds the complete CLI matrix, produces shell
and PowerShell installers and SHA-256 checksums, generates the final
Conventional Commit notes, adds a link comparing the previous and current tags,
and creates the GitHub Release with those artifacts. Creating the Release
triggers the GHCR workflow, which publishes the multi-architecture image and
provenance attestation.

```text
main changes
    -> release/next PR
    -> vMAJOR.MINOR.PATCH tag
    -> GitHub Release with CLI artifacts, notes, and tag comparison
    -> ghcr.io/chaba2/textbin (linux/amd64 and linux/arm64)
```

## Published CLI platforms

`dist` is pinned in `Cargo.toml` and treats that target list as the source of
truth for both release-PR dry runs and tagged releases:

| Platform | Rust target | Archive |
|----------|-------------|---------|
| Linux x86-64 | `x86_64-unknown-linux-gnu` | `.tar.xz` |
| Linux ARM64 | `aarch64-unknown-linux-gnu` | `.tar.xz` |
| macOS Intel | `x86_64-apple-darwin` | `.tar.xz` |
| macOS Apple Silicon | `aarch64-apple-darwin` | `.tar.xz` |
| Windows x86-64 | `x86_64-pc-windows-msvc` | `.zip` |

The GitHub Release also contains per-archive checksums, a combined checksum
file, and shell and PowerShell installers. Windows ARM64 and 32-bit platforms
are not currently release targets.

## Local preview

The Nix development shell includes git-cliff. Preview the complete changelog or
the next bump with:

```bash
make changelog
git cliff --bumped-version
```

`make changelog` rewrites `CHANGELOG.md`; discard that local preview if it was
not intended as a release change.
