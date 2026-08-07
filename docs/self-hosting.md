# Self-hosting Textbin

Textbin ships as a portable OCI image. The image does not assume Docker
Compose, a particular orchestrator, an ingress controller, or how secrets and
persistent storage are provided.

## Runtime contract

The server runs as the unprivileged `textbin` user with numeric UID and GID
`1000`. Its default command is:

```bash
/app/bin/textbin start
```

The process listens on `PORT` (`4000` by default). Terminate it using the
runtime's normal `SIGTERM` and grace-period mechanism.

The following configuration is required in production:

| Variable          | Purpose                                           |
|-------------------|---------------------------------------------------|
| `DATABASE_URL`    | PostgreSQL connection URL                         |
| `SECRET_KEY_BASE` | Phoenix signing and encryption secret             |
| `PHX_HOST`        | Public hostname used when generating URLs         |
| `PORT`            | HTTP listener port; defaults to `4000`            |
| `POOL_SIZE`       | Connections per PostgreSQL pool; defaults to `10` |

Generate `SECRET_KEY_BASE` with `mix phx.gen.secret` from a source checkout or
another cryptographically secure secret generator. Supply secrets through the
runtime's secret mechanism rather than baking them into an image layer.

## Writable paths

The image creates these paths and grants ownership to UID/GID `1000`:

| Path                       | Default variable         | Durability requirement                          |
|----------------------------|--------------------------|-------------------------------------------------|
| `/var/lib/textbin/pastes`  | `TEXTBIN_STORAGE_PATH`   | Persistent when using local storage             |
| `/var/lib/textbin/uploads` | `TEXTBIN_UPLOAD_TMP_DIR` | Writable staging space; persistence is optional |

The Dockerfile deliberately does not declare either path as a `VOLUME`.
Operators can supply bind mounts, named volumes, ephemeral disks, Kubernetes
volumes, or another implementation appropriate to their runtime.

Staged upload files are private, bounded by the configured paste limit, and
removed after finalization. Textbin tracks active staging files and periodically
removes stale files left by interrupted requests. Persisting the staging path
allows that cleanup to operate across container restarts; using ephemeral space
is also safe because unfinished request bodies are not committed paste data.
Provision staging capacity for the maximum expected number of concurrent
uploads. The current default maximum paste size is 1 MiB.

## Run migrations explicitly

The image never runs database migrations as a server startup side effect. Run
the included command once per deployment, with the same `DATABASE_URL` and
runtime secrets as the server:

```text
/app/bin/migrate
```

The command is safe to run repeatedly and applies every pending migration. In a
multi-instance deployment, run it as a dedicated release job before replacing
the application instances.

## Local storage

Select local storage with:

```text
TEXTBIN_STORAGE_BACKEND=local
TEXTBIN_STORAGE_PATH=/var/lib/textbin/pastes
```

The configured path must:

- be writable by UID/GID `1000`;
- survive application replacement and host restart;
- support atomic rename and file and directory `fsync` semantics; and
- have enough capacity for retained paste bodies and temporary files created
  adjacent to objects during atomic finalization.

Do not use a filesystem that ignores durability operations if acknowledged
writes must survive host failure. Network filesystems and storage drivers vary;
verify their rename and synchronization guarantees before production use.

## S3-compatible storage

Select S3-compatible storage with:

```text
TEXTBIN_STORAGE_BACKEND=s3
S3_ENDPOINT=https://objects.example.com
S3_BUCKET=textbin
S3_REGION=us-east-1
S3_ACCESS_KEY_ID=...
S3_SECRET_ACCESS_KEY=...
```

Textbin uses path-style object URLs and basic signed PUT, GET, and DELETE
operations. The bucket must exist before the server starts, and the credentials
must be restricted to object operations for that bucket. SeaweedFS and Garage
are suitable self-hosted implementations; verify compatibility before selecting
another provider.

S3 removes the need for persistent local paste storage, but the upload staging
path must still be writable. A paste is journaled in PostgreSQL before its object
is uploaded. Interrupted objects are claimed and removed by the background
cleaner without racing successful paste commits.

Do not change an existing installation from local to S3, or from S3 to local,
by changing only environment variables. Storage keys do not identify their
backend, and Textbin does not currently migrate existing objects between
backends.

## PostgreSQL and storage are one durability boundary

PostgreSQL stores ownership, visibility, expiration, content type, size,
checksum, and the blob storage key. Small UTF-8 textual bodies are stored inline
in PostgreSQL; larger and binary bodies use the selected storage backend.

Back up PostgreSQL and blob storage as a coordinated unit. The safest procedure
is:

1. stop or quiesce writes;
2. wait for active requests to finish;
3. snapshot PostgreSQL and the local/S3 blob store;
4. resume writes; and
5. regularly restore both snapshots into an isolated environment and verify
   paste reads.

Independent live snapshots can capture a database row without its object, or an
object without its row, because creation and deletion cross two systems. The
pending-upload journal repairs interrupted live operations; it is not a
replacement for coordinated backups.

## Upgrade procedure

For each upgrade:

1. read the release notes and back up PostgreSQL and blob storage;
2. run `/app/bin/migrate` from the new image as a dedicated job;
3. replace application instances using the runtime's normal rollout strategy;
4. verify login, paste creation, and reads from the configured backend; and
5. retain the previous image until the rollout is accepted.

Database migrations are expected to be forward-compatible during a normal
rolling deployment. Downgrading an image does not reverse migrations. Restore a
coordinated pre-upgrade backup when a migration must be rolled back.
