# Self-hosting Textbin

Textbin publishes a portable OCI image and supports the runtime contract in this
guide. The project does **not** maintain production Docker Compose, Kubernetes,
Helm, Terraform, cloud-provider, TLS, monitoring, or backup-scheduling
configurations. The `docker` commands below are illustrative translations of the
contract, not a production-ready stack. Operators own availability, network
policy, TLS lifecycle, secret management, monitoring, and backup automation.

## Image and dependency contract

Release images are published at `ghcr.io/chaba-dev/textbin`. They support
`linux/amd64` and `linux/arm64`.

- Use an exact release tag such as `0.1.0`, not `latest`, a major tag, or a minor
  tag.
- For reproducible deployments, resolve the multi-architecture manifest and pin
  `ghcr.io/chaba-dev/textbin@sha256:<manifest-digest>`. Record that digest with the
  backup and deployment metadata.
- Stable releases update their exact, major, minor, commit-SHA, and `latest`
  tags. Prereleases update only their exact and commit-SHA tags.
- The process runs as `textbin`, numeric UID/GID `1000`, and starts with
  `/app/bin/textbin start`.

GitHub creates a new GHCR package as private. Before the first public release,
the repository owner must make `chaba-dev/textbin` public in the package settings.
Until then, pulls require GHCR authentication.

A production installation requires:

1. PostgreSQL 17 on a private network;
2. either a durable POSIX filesystem or a supported S3-compatible object store;
3. writable upload staging space;
4. public HTTPS, terminated by a reverse proxy or by Textbin; and
5. Postmark email delivery if users need to register and confirm accounts.

PostgreSQL metadata and non-inline paste objects form one durability boundary.
Losing either can make paste content unreadable.

## Environment variables

Pass secrets through the platform's secret facility. Do not bake them into an
image, commit an environment file, put credentials in command history, or print
the effective environment while troubleshooting.

Required for every server and release command:

| Variable | Contract |
|---|---|
| `DATABASE_URL` | PostgreSQL URL, for example `ecto://textbin:<percent-encoded-password>@postgres/textbin_prod` |
| `SECRET_KEY_BASE` | At least 64 bytes of random signing material |
| `PHX_HOST` | Public hostname only, for example `textbin.example.com` |

Generate a secret without a source checkout:

```sh
openssl rand -base64 64
```

Application and database options:

| Variable | Default | Contract |
|---|---:|---|
| `PORT` | `4000` | HTTP listener, integer from 1 through 65535 |
| `POOL_SIZE` | `10` | PostgreSQL connections per application instance, positive integer |
| `ECTO_IPV6` | unset | Set to `true` or `1` when the database hostname resolves over IPv6 |
| `DNS_CLUSTER_QUERY` | unset | Erlang DNS clustering query; leave unset for one node or without distributed clustering |
| `TEXTBIN_INLINE_PASTE_BYTES` | `8192` | Non-negative threshold below which safe UTF-8 bodies remain in PostgreSQL |
| `TEXTBIN_UPLOAD_TMP_DIR` | `/var/lib/textbin/uploads` | Private upload spool |

Storage options:

| Variable | Required when | Default / contract |
|---|---|---|
| `TEXTBIN_STORAGE_BACKEND` | Optional | `local`; accepted values are `local` and `s3` |
| `TEXTBIN_STORAGE_PATH` | Local | `/var/lib/textbin/pastes` |
| `S3_ENDPOINT` | S3 | Absolute HTTP(S) origin; path-style access is used |
| `S3_BUCKET` | S3 | Existing bucket name |
| `S3_REGION` | S3 | `us-east-1` |
| `S3_ACCESS_KEY_ID` | S3 | Bucket-scoped access key |
| `S3_SECRET_ACCESS_KEY` | S3 | Bucket-scoped secret key |

Email options for supported production registration:

| Variable | Required when | Contract |
|---|---|---|
| `TEXTBIN_MAILER_BACKEND` | Sending email | Set to `postmark` |
| `POSTMARK_API_KEY` | Postmark | Postmark server API token |
| `MAIL_FROM_ADDRESS` | Sending email | Verified sender address |
| `MAIL_FROM_NAME` | Optional | Defaults to `Textbin` |

Without a production mail backend, the server can run but new users cannot
receive confirmation or login links. Validate the sender domain and outbound
HTTPS access to Postmark before opening registration.

Direct TLS options:

| Variable | Default | Contract |
|---|---:|---|
| `TLS_CERT_PATH` | unset | Readable PEM certificate; must be set with `TLS_KEY_PATH` |
| `TLS_KEY_PATH` | unset | Readable PEM private key; must be set with `TLS_CERT_PATH` |
| `HTTPS_PORT` | `4443` | Internal HTTPS listener, integer from 1 through 65535 |

`PHX_SERVER=true` is already set in the image. Invalid integers, unsupported
backends, incomplete TLS pairs, unreadable TLS files, and missing backend secrets
fail startup. Keep one identical environment/secret set for migration jobs,
admin jobs, and application instances.

## PostgreSQL

Textbin's tested production baseline is PostgreSQL 17. Use a supported PostgreSQL
17 minor release, UTF-8 database encoding, durable storage, and routine database
maintenance. The application role needs connect, schema migration, table,
sequence, and advisory-lock privileges in its own database; it does not need a
PostgreSQL superuser or access to other databases. Do not expose PostgreSQL to
the public Internet.

Size `max_connections` for at least:

```text
(maximum simultaneous Textbin instances × POOL_SIZE) + maintenance headroom
```

Migration and operator jobs open transient connections, and backup tools need
headroom. Start with the default pool and increase it only after observing queue
time and database capacity. Each replica gets its own pool.

Before deploying Textbin, verify from the same private network and with the
application credentials. PostgreSQL tools expect a `postgresql://` URL rather
than Ecto's `ecto://` scheme:

```sh
PGDATABASE_URL='postgresql://textbin:<percent-encoded-password>@postgres:5432/textbin_prod'
pg_isready -d "$PGDATABASE_URL"
psql "$PGDATABASE_URL" -v ON_ERROR_STOP=1 -c 'select current_database(), version();'
unset PGDATABASE_URL
```

## Writable paths and upload capacity

The image creates both paths with UID/GID `1000` and deliberately declares no
Docker `VOLUME`:

| Path | Durability |
|---|---|
| `/var/lib/textbin/pastes` | Persistent and backed up for local storage |
| `/var/lib/textbin/uploads` | Writable; persistence is optional |

Upload files are mode-restricted, removed after finalization, and reaped when
stale. Ephemeral upload space is safe because an unfinished body is not committed
paste data. Persistent staging lets cleanup continue across restarts. Provision
at least `maximum concurrent uploads × maximum paste size`, plus filesystem
overhead and operational headroom. The current maximum paste size is 1 MiB.

## Migrations

The server never migrates on startup. Run exactly one migration job from the new
image before starting or rolling application instances:

```sh
docker run --rm --network textbin-private --env-file /run/textbin/runtime.env \
  ghcr.io/chaba-dev/textbin:0.1.0 /app/bin/migrate
```

The command is idempotent and uses a PostgreSQL advisory lock. Keep the job logs;
a non-zero exit means the rollout must stop. Do not start the new server version
until migrations succeed.

## Local-storage deployment

Local storage requires one persistent filesystem mounted at
`/var/lib/textbin/pastes`. It must support same-filesystem atomic rename plus file
and directory `fsync`. Shared multi-node access is safe only when the filesystem
provides those semantics consistently to every node. Otherwise run one Textbin
instance or use S3-compatible storage.

An illustrative environment file (replace all placeholders and set mode `0600`):

```dotenv
DATABASE_URL=ecto://textbin:<percent-encoded-password>@postgres:5432/textbin_prod
SECRET_KEY_BASE=<openssl-rand-base64-64-output>
PHX_HOST=textbin.example.com
POOL_SIZE=10
TEXTBIN_STORAGE_BACKEND=local
TEXTBIN_STORAGE_PATH=/var/lib/textbin/pastes
TEXTBIN_UPLOAD_TMP_DIR=/var/lib/textbin/uploads
TEXTBIN_MAILER_BACKEND=postmark
POSTMARK_API_KEY=<postmark-server-token>
MAIL_FROM_ADDRESS=textbin@example.com
```

Illustrative single-node server command:

```sh
docker volume create textbin-pastes
docker volume create textbin-uploads
docker run --rm --user 0:0 \
  --mount type=volume,src=textbin-pastes,dst=/var/lib/textbin/pastes \
  --mount type=volume,src=textbin-uploads,dst=/var/lib/textbin/uploads \
  --entrypoint chown ghcr.io/chaba-dev/textbin:0.1.0 \
  -R 1000:1000 /var/lib/textbin/pastes /var/lib/textbin/uploads

docker run --name textbin --read-only --restart unless-stopped \
  --network textbin-private --env-file /run/textbin/runtime.env \
  --mount type=volume,src=textbin-pastes,dst=/var/lib/textbin/pastes \
  --mount type=volume,src=textbin-uploads,dst=/var/lib/textbin/uploads \
  --tmpfs /app/tmp:rw,noexec,nosuid,nodev,size=16m,mode=0700,uid=1000,gid=1000 \
  --publish 127.0.0.1:4000:4000 \
  ghcr.io/chaba-dev/textbin:0.1.0
```

The private `/app/tmp` tmpfs is required with `--read-only`: the OTP release
launcher writes evaluated runtime configuration there before boot. Keep it
ephemeral because that configuration contains resolved secrets.

The volume must already be writable by UID/GID `1000`. Verify before migration:

```sh
docker run --rm --user 1000:1000 \
  --mount type=volume,src=textbin-pastes,dst=/var/lib/textbin/pastes \
  --entrypoint sh ghcr.io/chaba-dev/textbin:0.1.0 -c \
  'set -eu; p=/var/lib/textbin/pastes/.permission-check; umask 077; : > "$p"; sync "$p"; rm "$p"'
```

After startup, perform the end-to-end paste check under [Verification](#verification).
It writes a body larger than the inline threshold, proving database and mounted
blob storage connectivity together.

## S3-compatible deployment

Textbin uses path-style, AWS Signature V4 PUT, GET, and DELETE requests. The
bucket must exist. Credentials need only object read, write, and delete access
within that bucket; deny bucket administration and access to other buckets. Keep
the endpoint private when possible and never expose its administration UI or API
publicly. SeaweedFS and Garage are tested development targets; test any provider's
path-style and signing compatibility before production use.

Illustrative S3 additions to the common environment:

```dotenv
TEXTBIN_STORAGE_BACKEND=s3
S3_ENDPOINT=https://objects.internal.example.com
S3_BUCKET=textbin-prod
S3_REGION=us-east-1
S3_ACCESS_KEY_ID=<bucket-scoped-access-key>
S3_SECRET_ACCESS_KEY=<bucket-scoped-secret-key>
TEXTBIN_UPLOAD_TMP_DIR=/var/lib/textbin/uploads
```

No paste volume is required:

```sh
docker volume create textbin-uploads
docker run --rm --user 0:0 \
  --mount type=volume,src=textbin-uploads,dst=/var/lib/textbin/uploads \
  --entrypoint chown ghcr.io/chaba-dev/textbin:0.1.0 \
  -R 1000:1000 /var/lib/textbin/uploads

docker run --name textbin --read-only --restart unless-stopped \
  --network textbin-private --env-file /run/textbin/runtime.env \
  --mount type=volume,src=textbin-uploads,dst=/var/lib/textbin/uploads \
  --tmpfs /app/tmp:rw,noexec,nosuid,nodev,size=16m,mode=0700,uid=1000,gid=1000 \
  --publish 127.0.0.1:4000:4000 \
  ghcr.io/chaba-dev/textbin:0.1.0
```

Use the object store's supported CLI from the Textbin network to put, read, and
delete a disposable object using the application credentials. Then perform the
end-to-end paste check below. A bucket-list operation alone is insufficient:
Textbin needs object PUT, GET, and DELETE. Do not log the credentials or probe
contents.

Never switch an existing installation between local and S3 by changing only the
environment. Storage keys do not identify a backend, and Textbin does not migrate
existing objects.

## Networking, TLS, and probes

### Reverse proxy (recommended)

Publish `PORT` only to a trusted proxy, ingress, or load balancer. The proxy must:

- terminate public TLS for `PHX_HOST` and redirect public HTTP to HTTPS;
- preserve the original `Host` header;
- support WebSocket upgrades for `/live/websocket`;
- forward normal HTTP to the private `PORT`; and
- use `/readyz` to select traffic-ready instances.

Textbin generates canonical URLs as `https://PHX_HOST` on public port 443.
Non-standard public HTTPS ports are not supported. Textbin does not currently
trust or rewrite `Forwarded` or `X-Forwarded-*` headers. Proxy-set values cannot
override the canonical host or scheme, and request logs see the immediate peer
address. Configure the proxy to replace, not append, forwarded headers anyway,
and do not use them for authorization or abuse decisions.

### Direct TLS

Mount a certificate and key read-only, readable by UID/GID `1000`, then set:

```dotenv
TLS_CERT_PATH=/run/secrets/textbin/tls.crt
TLS_KEY_PATH=/run/secrets/textbin/tls.key
HTTPS_PORT=4443
```

Map public TCP 443 to `HTTPS_PORT`; the HTTP `PORT` remains enabled for private
probes. Every replica needs a certificate valid for `PHX_HOST`. Replace renewed
files atomically and restart or roll instances so Erlang loads them. Certificate
issuance and renewal are operator responsibilities.

### Health checks

| Endpoint | Success | Meaning |
|---|---|---|
| `GET /healthz` | `200 ok` | BEAM and HTTP listener are alive; no dependency check |
| `GET /readyz` | `200 ready` | A bounded `SELECT 1` succeeded against PostgreSQL |

`/readyz` returns 503 on database failure and never includes connection details.
Use `/healthz` for restart decisions and `/readyz` for rollout and load-balancer
readiness. Neither endpoint verifies blob storage; use the end-to-end paste probe
after deployment and alert on application storage errors.

## First user and platform administrator

1. Confirm Postmark delivery and `MAIL_FROM_ADDRESS` before exposing Textbin.
2. Visit `https://PHX_HOST/users/register`, submit the first user's email, and
   follow the emailed confirmation/login link.
3. While that confirmed user is logged in, set a password in user settings if API
   token creation is needed.
4. Grant platform authority from the running container:

   ```sh
   docker exec textbin /app/bin/grant-platform-admin admin@example.com
   ```

The command accepts exactly one email, requires an existing confirmed,
non-suspended human user, and records a platform audit event. It is also the
audited recovery command when all normal admin access is lost. It uses release
RPC, so execute it against a running application container with its normal
environment; do not edit the database directly. Organization owner/admin roles
do not grant platform authority.

## Verification

Check probes first:

```sh
curl --fail --silent --show-error https://textbin.example.com/healthz
curl --fail --silent --show-error https://textbin.example.com/readyz
```

For a full database-and-blob smoke test, use a dedicated operator account with a
password. Keep the returned token out of shell tracing and revoke it afterward:

```sh
(
  set -euo pipefail
  set +x
  : "${TEXTBIN_OPERATOR_PASSWORD:?set TEXTBIN_OPERATOR_PASSWORD}"

  BASE_URL=https://textbin.example.com
  TOKEN=
  PASTE_ID=

  cleanup() {
    status=$?
    trap - EXIT
    set +e
    if [[ -n "$TOKEN" && -n "$PASTE_ID" ]]; then
      curl --fail --silent --show-error --output /dev/null -X DELETE \
        -H "authorization: Bearer $TOKEN" \
        "$BASE_URL/api/v1/pastes/$PASTE_ID"
    fi
    if [[ -n "$TOKEN" ]]; then
      curl --fail --silent --show-error --output /dev/null -X DELETE \
        -H "authorization: Bearer $TOKEN" "$BASE_URL/api/v1/me/token"
    fi
    rm -f /tmp/textbin-probe.bin /tmp/textbin-probe-restored.bin
    unset TOKEN TEXTBIN_OPERATOR_PASSWORD
    exit "$status"
  }
  trap cleanup EXIT

  TOKEN="$(
    jq -cn \
      --arg email 'operator@example.com' \
      --arg password "$TEXTBIN_OPERATOR_PASSWORD" \
      --arg name 'restore-drill' \
      '{email: $email, password: $password, name: $name}' \
      | curl --fail --silent --show-error \
          -H 'content-type: application/json' --data-binary @- \
          "$BASE_URL/api/v1/auth/tokens" \
      | jq -er '.data.api_token'
  )"

  dd if=/dev/urandom bs=16384 count=1 2>/dev/null > /tmp/textbin-probe.bin
  EXPECTED_SHA256="$(sha256sum /tmp/textbin-probe.bin | cut -d' ' -f1)"
  PASTE_ID="$(curl --fail --silent --show-error \
    -H "authorization: Bearer $TOKEN" \
    -H 'content-type: application/octet-stream' \
    --data-binary @/tmp/textbin-probe.bin \
    "$BASE_URL/api/v1/pastes" | jq -er '.data.id')"

  curl --fail --silent --show-error \
    -H "authorization: Bearer $TOKEN" \
    "$BASE_URL/api/v1/pastes/$PASTE_ID" \
    | jq -er '.data.data_base64' \
    | base64 -d > /tmp/textbin-probe-restored.bin
  test "$(sha256sum /tmp/textbin-probe-restored.bin | cut -d' ' -f1)" = "$EXPECTED_SHA256"
  echo "Textbin external paste integrity verified"
)
```

The random 16 KiB binary body exceeds the default inline threshold and therefore
exercises the configured external storage backend. A successful checksum proves
that API authorization, PostgreSQL metadata, object write/read, and integrity
verification all worked.

## Back up and restore

PostgreSQL records include object keys, sizes, and SHA-256 checksums. Blob writes
and database commits cross systems, so independent live backups can capture a row
without its object or an object without its row. The pending-upload journal
repairs interrupted live operations; it is not a backup mechanism.

### Coordinated backup

1. Record the exact image digest and runtime configuration names (not secret
   values).
2. Stop all Textbin instances or block write traffic and let active requests
   finish. Confirm no server can create or delete a paste.
3. Back up PostgreSQL using PostgreSQL 17 tooling, for example `pg_dump` in custom
   format, and capture its checksum.
4. While writes remain stopped, snapshot/copy `/var/lib/textbin/pastes` or the
   complete S3 bucket, including object versions if versioning is enabled.
5. Capture the blob backup's provider snapshot/version identifier and inventory.
6. Resume writes only after both backups have completed. Store both artifacts and
   their identifiers as one backup set.

For example, while writes are stopped, PostgreSQL custom-format and local-storage
backups can be created with PostgreSQL 17 and standard archive tools:

```sh
umask 077
BACKUP_DIR=/secure-backups/textbin-2026-08-26T210000Z
PGDATABASE_URL='postgresql://textbin:<percent-encoded-password>@postgres:5432/textbin_prod'
install -d -m 0700 "$BACKUP_DIR"
pg_dump --format=custom --file="$BACKUP_DIR/postgres.dump" "$PGDATABASE_URL"
tar --create --file="$BACKUP_DIR/pastes.tar" \
  --directory=/var/lib/textbin/pastes .
sha256sum "$BACKUP_DIR/postgres.dump" "$BACKUP_DIR/pastes.tar" \
  > "$BACKUP_DIR/SHA256SUMS"
unset PGDATABASE_URL
```

Run those tools where the durable paste path is mounted read-only. For S3, use a
provider-consistent bucket snapshot or versioned replication operation instead
of `pastes.tar`, then record its immutable identifier and inventory beside the
database dump.

Upload staging is not durable paste data and need not be backed up. The secret
key is needed to preserve existing signed sessions but belongs in the secret
manager's protected backup, not beside ordinary backup logs.

### Restore drill

Run this drill regularly, not only after an incident:

1. Create an isolated PostgreSQL 17 database and isolated local volume or bucket.
   Ensure it cannot receive production traffic or email.
2. Restore the blob snapshot first, preserving every object key.
3. Restore PostgreSQL with `pg_restore --exit-on-error --clean --if-exists` (or
   the equivalent for the chosen backup format).
4. Configure the recorded image digest against the restored database and blob
   location. Use a new hostname and secret delivery path.
5. Run `/app/bin/migrate` only if intentionally validating an upgrade; otherwise
   start the exact backed-up image.
6. Require `/readyz` to return 200. Compare expected database row counts and the
   blob inventory with the backup manifest.
7. Select at least one known external paste from the backup and read it through
   the API. Compare the returned bytes with its recorded SHA-256 checksum. Run
   the binary end-to-end probe from [Verification](#verification) to prove new
   writes and reads too.
8. Record the restore duration, checks performed, missing objects, checksum
   failures, and cleanup of the isolated environment.

For an isolated database that already exists and an empty local restore path,
the corresponding restore commands are:

```sh
umask 077
BACKUP_DIR=/secure-backups/textbin-2026-08-26T210000Z
RESTORE_DATABASE_URL='postgresql://textbin_restore:<percent-encoded-password>@restore-postgres:5432/textbin_restore'
cd "$BACKUP_DIR"
sha256sum --check SHA256SUMS
test -z "$(find /restore/textbin/pastes -mindepth 1 -print -quit)"
tar --extract --file=pastes.tar --directory=/restore/textbin/pastes
pg_restore --exit-on-error --clean --if-exists --no-owner \
  --dbname="$RESTORE_DATABASE_URL" postgres.dump
unset RESTORE_DATABASE_URL
```

Restore an S3 snapshot with the provider's immutable snapshot/version identifier
before `pg_restore`. Keep the restore bucket isolated and preserve object keys.

A database that starts is not a successful restore. The drill succeeds only when
metadata exists **and** externally stored paste bytes read with the expected
checksum.

## Upgrades and rollback

Before every upgrade, read all intervening release notes and complete a
coordinated backup and recent restore drill.

Single node:

1. stop the old server;
2. run `/app/bin/migrate` from the exact new image;
3. start the new image with unchanged durable storage and secrets; and
4. require readiness, login, and the end-to-end storage probe before reopening
   traffic.

Rolling deployment:

1. run one migration job from the new image while old instances remain serving;
2. stop if migration fails;
3. replace instances gradually, adding each only after `/readyz` succeeds; and
4. verify login and external paste create/read before completing the rollout.

Migrations are designed to be forward-compatible with the previous application
during a normal roll. They are not reversible, and launching an older image after
new migrations is not a supported rollback. If application rollback is unsafe,
stop writes and restore the coordinated pre-upgrade PostgreSQL and blob backup,
then start its recorded image digest. Never restore only PostgreSQL or only blobs.

## Troubleshooting without exposing secrets

| Symptom | Safe checks |
|---|---|
| Startup says a required variable is missing | Check that the secret/config key is attached; print key names or presence only, never values |
| Database connection refused or `/readyz` is 503 | Run `pg_isready` from the application network; check DNS, port, TLS policy, role limits, and `replicas × POOL_SIZE` |
| Migration waits or fails | Ensure only the release job is migrating, inspect PostgreSQL advisory locks and migration logs, and do not start the new image |
| Local writes fail | Check mount ownership is `1000:1000`, free space/inodes, read-only flags, and rename/fsync support |
| S3 returns 403 | Check clock synchronization, endpoint/region, path-style support, and object-level policy without printing keys |
| S3 returns 404 | Confirm bucket and endpoint, then check whether database and blob backups came from the same set |
| Uploads fail but small pastes work | Check staging ownership, free space, inode availability, and the 1 MiB request limit |
| Confirmation mail is absent | Check Postmark delivery/activity, verified sender, outbound HTTPS, and recipient suppression state; never log the API token |
| Browser loops or LiveView disconnects | Confirm public HTTPS, `PHX_HOST`, preserved `Host`, WebSocket upgrade support, and proxy idle timeout |
| TLS listener will not start | Check that both PEM paths are regular readable files for UID 1000 and that `HTTPS_PORT` is free |

Application errors include a request ID where available. Correlate that ID with
proxy and application logs. Sanitize database URLs, authorization headers, API
tokens, cookies, Postmark credentials, and S3 credentials before sharing logs.
