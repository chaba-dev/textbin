# Textbin website

This directory is the static public website for Textbin. It is intentionally
separate from the Phoenix application: Cloudflare Pages serves these files,
while the stateful application still requires a BEAM runtime, PostgreSQL, and a
storage backend.

## Local preview

Serve this directory with any static file server, for example:

```sh
python3 -m http.server --directory website 4173
```

## Cloudflare Pages

The `textbin` Pages project deploys this repository with:

- production branch: `main`
- build command: none
- build output directory: `website`

Cloudflare applies the response headers in `_headers` during deployment.
