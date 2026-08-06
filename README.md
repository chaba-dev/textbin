# Textbin

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

## Docker Compose

Start Postgres for local development:

```sh
docker compose up db
```

Then run `mix setup` and `mix phx.server` locally as usual.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Self-hosting

The production OCI image is runtime-agnostic and includes an explicit migration
command plus writable locations for local paste storage and staged uploads. See
the [self-hosting guide](docs/self-hosting.md) for the image contract, storage
configuration, backup boundaries, and upgrade procedure.

## API binary content

API v1 returns UTF-8 textual paste bodies in `data`. Arbitrary binary bodies use
an explicit Base64 representation so JSON remains valid:

```json
{
  "data": null,
  "data_base64": "/wAB",
  "data_encoding": "base64",
  "content_type": "application/octet-stream"
}
```

The `textbin-client` 0.2 release reflects this binary-capable contract by
exposing `Paste.data` as bytes instead of a Rust `String`. This is a deliberate
pre-1.0 breaking change; consumers that only accept text should use
`Paste::text()`.

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
