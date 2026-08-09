#!/usr/bin/env bash
# Database Postgres entrypoint (Host Component tree; runs inside the container).
# Copies TLS material to postgres-owned paths, then hands off to the image entrypoint.
# ADR-0049 / #188.
set -euo pipefail

CERT_SRC=/etc/database-certs
CERT_DST=/var/lib/postgresql/certs
CONF_SRC=/etc/database-conf

mkdir -p "${CERT_DST}"
cp "${CERT_SRC}/ca.crt" "${CERT_DST}/ca.crt"
cp "${CERT_SRC}/server.crt" "${CERT_DST}/server.crt"
cp "${CERT_SRC}/server.key" "${CERT_DST}/server.key"
chown postgres:postgres "${CERT_DST}/ca.crt" "${CERT_DST}/server.crt" "${CERT_DST}/server.key"
chmod 0644 "${CERT_DST}/ca.crt" "${CERT_DST}/server.crt"
chmod 0600 "${CERT_DST}/server.key"

[[ -f "${CONF_SRC}/pg_hba.conf" ]] || {
  echo "database-entrypoint: missing ${CONF_SRC}/pg_hba.conf" >&2
  exit 1
}
[[ -f "${CONF_SRC}/pg_ident.conf" ]] || {
  echo "database-entrypoint: missing ${CONF_SRC}/pg_ident.conf" >&2
  exit 1
}

# Small-Host-sensible defaults (footprint product knobs deferred — ADR-0049).
exec docker-entrypoint.sh postgres \
  -c ssl=on \
  -c ssl_cert_file="${CERT_DST}/server.crt" \
  -c ssl_key_file="${CERT_DST}/server.key" \
  -c ssl_ca_file="${CERT_DST}/ca.crt" \
  -c hba_file="${CONF_SRC}/pg_hba.conf" \
  -c ident_file="${CONF_SRC}/pg_ident.conf" \
  -c password_encryption=scram-sha-256 \
  -c listen_addresses='*' \
  -c shared_buffers=32MB \
  -c max_connections=40 \
  "$@"
