# Textbin website

This directory is the Hugo source for Textbin's public website. It is
intentionally separate from the Phoenix application: Cloudflare Pages builds
and serves this site, while the stateful application still requires a BEAM
runtime, PostgreSQL, and a storage backend.

The site uses custom Hugo layouts and Hugo Pipes rather than a third-party theme
or JavaScript frontend. Product demonstrations are semantic HTML and CSS so
they stay responsive and do not drift from the public product description.

## Development

From the repository root, enter the Nix development shell and use the website
targets:

```sh
nix develop
make website-dev
make website-build
make website-clean
```

`website-build` writes the production site to `website/public` with minified,
fingerprinted CSS. Generated output is not committed.

## Cloudflare Pages

The `textbin` Pages project deploys this repository with:

- production branch: `main`
- root directory: `website`
- build command: `hugo --minify`
- build output directory: `public`
- environment variable: `HUGO_VERSION=0.164.0` in preview and production

Cloudflare applies the response headers in `static/_headers` after Hugo copies
them into the build output.
