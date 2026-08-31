#!/bin/sh
# Build Umami DATABASE_URL from the Platform Database mTLS binding (ADR-0049).
# PGHOST/PGUSER/PGDATABASE/PGSSL* arrive via 50-platform-database.conf drop-in.
#
# prisma migrate deploy does not authenticate with client certificates; apply
# prisma/migrations/*.sql via psql (libpq PGSSL*) and skip Prisma migrate.
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

analytics_ensure_psql() {
  if command -v psql >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v apk >/dev/null 2>&1; then
    echo "analytics entrypoint: psql missing and apk unavailable" >&2
    return 1
  fi
  apk add --no-cache postgresql-client >/dev/null
}

analytics_psql() {
  psql -v ON_ERROR_STOP=1 "$@"
}

analytics_apply_prisma_migrations() {
  local migrations_dir="/app/prisma/migrations"
  local name sql checksum migration_id applied

  analytics_ensure_psql || return 1

  analytics_psql -c '
CREATE TABLE IF NOT EXISTS "_prisma_migrations" (
  "id" VARCHAR(36) PRIMARY KEY,
  "checksum" VARCHAR(64) NOT NULL,
  "finished_at" TIMESTAMPTZ,
  "migration_name" VARCHAR(255) NOT NULL,
  "logs" TEXT,
  "rolled_back_at" TIMESTAMPTZ,
  "started_at" TIMESTAMPTZ NOT NULL DEFAULT now(),
  "applied_steps_count" INTEGER NOT NULL DEFAULT 0
);'

  for name in $(ls -1 "${migrations_dir}" 2>/dev/null | sort); do
    sql="${migrations_dir}/${name}/migration.sql"
    [ -f "${sql}" ] || continue

    applied="$(analytics_psql -tAc \
      "SELECT 1 FROM \"_prisma_migrations\" WHERE migration_name = '${name}' AND rolled_back_at IS NULL LIMIT 1" \
      2>/dev/null | tr -d '[:space:]')"
    if [ "${applied}" = "1" ]; then
      continue
    fi

    checksum="$(sha256sum "${sql}" | awk '{print $1}')"
    migration_id="$(cat /proc/sys/kernel/random/uuid)"

    tmp="$(mktemp)"
    {
      printf 'BEGIN;\n'
      cat "${sql}"
      printf '\nINSERT INTO "_prisma_migrations" (id, checksum, finished_at, migration_name, applied_steps_count)\n'
      printf "VALUES ('%s', '%s', NOW(), '%s', 1);\n" "${migration_id}" "${checksum}" "${name}"
      printf 'COMMIT;\n'
    } >"${tmp}"
    analytics_psql -f "${tmp}"
    rm -f "${tmp}"
    echo "analytics entrypoint: applied migration ${name}"
  done
}

cd /app
analytics_apply_prisma_migrations
export SKIP_DB_MIGRATION=1
exec sh scripts/start-docker.sh
