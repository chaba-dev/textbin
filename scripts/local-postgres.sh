#!/usr/bin/env bash
#
# Local PostgreSQL lifecycle for this checkout on machines without Docker
# (Amp Orbs).
#
# Workstations run the container from docker-compose.yml, which exports its
# socket into tmp/postgres-socket. This script gives Docker-less environments the
# same contract: a cluster whose data lives in tmp/postgres and whose socket
# lives in tmp/postgres-socket, never on a TCP port. Both paths therefore share
# the single socket_dir that config/dev.exs and config/test.exs configure.
#
# Usage: scripts/local-postgres.sh <start|stop|status|psql> [psql args...]

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pgdata="$repo_root/tmp/postgres"
socket_dir="$repo_root/tmp/postgres-socket"

# Clusters created by earlier checkouts live under .nix/postgres. Adopting that
# directory keeps the database it holds instead of initializing an empty cluster
# beside it.
legacy_pgdata="$repo_root/.nix/postgres"

# Postgres takes the socket directory and the (absent) TCP listener from server
# configuration, never from the command line, so these settings are the single
# definition of how the cluster is exposed. They live in an included file rather
# than in initdb's postgresql.conf so that every start can rewrite them
# wholesale: a cluster created by an earlier checkout listened on
# 127.0.0.1:5433, and rewriting on start converges it instead of leaving a TCP
# listener behind that the application no longer expects.
write_config() {
  local conf="$pgdata/postgresql.conf"
  local include_line="include = 'textbin.conf'"

  if ! grep -qx "$include_line" "$conf"; then
    printf '\n# Local socket-only settings; see scripts/local-postgres.sh.\n%s\n' "$include_line" >>"$conf"
  fi

  cat >"$pgdata/textbin.conf" <<CONFIG
# Managed by scripts/local-postgres.sh. Change that script, not this file.
#
# Local connections are trusted, so reaching the socket is equivalent to being
# the database superuser: permissions stay at 0700 and no TCP listener exists
# that could hand the same access to another machine or user.
listen_addresses = ''
unix_socket_directories = '$socket_dir'
unix_socket_permissions = 0700

# The port only names the socket file (.s.PGSQL.5432) that clients derive from
# it; with an empty listen_addresses there is no TCP listener on that number.
port = 5432

# Development data is reproducible and restart speed matters more than crash
# durability, so skip the write barriers a production cluster would need.
fsync = off
synchronous_commit = off
full_page_writes = off
CONFIG
}

# The legacy directory is moved rather than copied, so the two locations can
# never hold diverging clusters. A running legacy server has to stop first: it
# keeps its socket inside its data directory, so it would otherwise serve a
# directory that no longer exists.
adopt_legacy_cluster() {
  if [ ! -s "$legacy_pgdata/PG_VERSION" ] || [ -e "$pgdata" ]; then
    return
  fi

  if pg_ctl --pgdata="$legacy_pgdata" status >/dev/null 2>&1; then
    pg_ctl --pgdata="$legacy_pgdata" --wait --timeout=5 stop >/dev/null
  fi

  mkdir -p "$(dirname "$pgdata")"
  mv "$legacy_pgdata" "$pgdata"
}

# A cluster is initialized once, but `start` runs on every resume, so an
# existing data directory is validated rather than recreated. A directory that
# initdb did not finish writing is refused instead of silently repaired: it
# would otherwise be promoted into a cluster that is missing relations.
init_cluster() {
  adopt_legacy_cluster

  if [ -f "$pgdata/PG_VERSION" ]; then
    local postgres_major
    postgres_major="$(postgres --version | awk '{print $3}' | cut -d. -f1)"

    if [ "$(cat "$pgdata/PG_VERSION")" != "$postgres_major" ]; then
      echo "PostgreSQL data directory uses a different major version; remove tmp/postgres and rerun." >&2
      exit 1
    fi

    return
  fi

  if [ -e "$pgdata" ]; then
    echo "PostgreSQL data directory is incomplete; remove tmp/postgres and rerun." >&2
    exit 1
  fi

  # Interrupted initialization must stay retryable, so build the cluster in a
  # staging directory and promote it only after initdb has completed.
  local staging="$pgdata.initializing"
  rm -rf "$staging"
  mkdir -p "$(dirname "$pgdata")"
  # The application connects as `postgres` (see config/dev.exs and
  # config/test.exs), so initdb makes that role the superuser; `mix ecto.create`
  # and extension migrations need it.
  initdb --pgdata="$staging" --username=postgres --auth=trust >/dev/null
  mv "$staging" "$pgdata"
}

running() {
  [ -f "$pgdata/PG_VERSION" ] && pg_ctl --pgdata="$pgdata" status >/dev/null 2>&1
}

case "${1:-start}" in
start)
  init_cluster

  # A cluster left running by an earlier checkout still listens on TCP and keeps
  # its socket inside the data directory. Both are start-time settings, so that
  # instance is stopped and started again with the managed configuration; an
  # instance already answering on the managed socket is left running.
  if running && ! pg_isready --host="$socket_dir" --quiet; then
    pg_ctl --pgdata="$pgdata" --wait --timeout=5 stop >/dev/null
  fi

  if ! running; then
    write_config
    # The socket lives outside the data directory, so the directory has to exist
    # before the server starts; creating it here is safe even when another
    # Postgres already owns the path (the container's socket directory on a
    # workstation). Access is controlled by the socket's own 0700 permissions in
    # the configuration above, not by this directory.
    mkdir -p "$socket_dir"
    pg_ctl --pgdata="$pgdata" --wait --timeout=5 start >/dev/null
  fi

  pg_isready --host="$socket_dir" --quiet

  echo "PostgreSQL is listening on $socket_dir/.s.PGSQL.5432"
  ;;
stop)
  if running; then
    pg_ctl --pgdata="$pgdata" --wait --timeout=5 stop >/dev/null
  fi
  ;;
status)
  if ! running; then
    echo "PostgreSQL is not running" >&2
    exit 1
  fi

  pg_ctl --pgdata="$pgdata" status
  ;;
psql)
  shift
  exec psql --host="$socket_dir" --username=postgres --dbname=textbin_dev "$@"
  ;;
*)
  echo "usage: scripts/local-postgres.sh <start|stop|status|psql> [psql args...]" >&2
  exit 64
  ;;
esac
