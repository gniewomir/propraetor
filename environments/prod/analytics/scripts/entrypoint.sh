#!/bin/sh
# Build Umami DATABASE_URL from the Platform Database mTLS binding (ADR-0049).
# PGHOST/PGUSER/PGDATABASE/PGSSL* arrive via 50-platform-database.conf drop-in.
set -eu

if [ -z "${DATABASE_URL:-}" ]; then
  if [ -z "${PGHOST:-}" ] || [ -z "${PGUSER:-}" ] || [ -z "${PGDATABASE:-}" ]; then
    echo "analytics entrypoint: DATABASE_URL or PG* database binding required" >&2
    exit 1
  fi

  port="${PGPORT:-5432}"
  ssl_mode="${PGSSLMODE:-verify-full}"
  query="sslmode=${ssl_mode}"

  if [ -n "${PGSSLROOTCERT:-}" ]; then
    query="${query}&sslrootcert=${PGSSLROOTCERT}"
  fi
  if [ -n "${PGSSLCERT:-}" ]; then
    query="${query}&sslcert=${PGSSLCERT}"
  fi
  if [ -n "${PGSSLKEY:-}" ]; then
    query="${query}&sslkey=${PGSSLKEY}"
  fi

  export DATABASE_URL="postgresql://${PGUSER}@${PGHOST}:${port}/${PGDATABASE}?${query}"
fi

if [ -z "${APP_SECRET:-}" ]; then
  echo "analytics entrypoint: APP_SECRET required" >&2
  exit 1
fi

cd /app
exec sh scripts/start-docker.sh
