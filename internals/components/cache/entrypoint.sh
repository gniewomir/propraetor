#!/bin/sh
# Cache Valkey entrypoint (Host Component tree; runs inside the container).
# Copies TLS material to a writable runtime dir (image user cannot read Host 0600
# keys in place), then execs valkey-server. ADR-0055 / #221.
# Uses POSIX sh — valkey alpine may lack bash (exit 127 on #!/usr/bin/env bash).
set -eu

CERT_SRC=/etc/cache-certs
CONF_SRC=/etc/valkey
RUNTIME=/tmp/propraetor-cache

[ -f "${CERT_SRC}/ca.crt" ] || {
  echo "cache-entrypoint: missing ${CERT_SRC}/ca.crt" >&2
  exit 1
}
[ -f "${CERT_SRC}/server.crt" ] || {
  echo "cache-entrypoint: missing ${CERT_SRC}/server.crt" >&2
  exit 1
}
[ -f "${CERT_SRC}/server.key" ] || {
  echo "cache-entrypoint: missing ${CERT_SRC}/server.key" >&2
  exit 1
}
[ -f "${CONF_SRC}/valkey.conf" ] || {
  echo "cache-entrypoint: missing ${CONF_SRC}/valkey.conf" >&2
  exit 1
}
[ -f "${CONF_SRC}/users.acl" ] || {
  echo "cache-entrypoint: missing ${CONF_SRC}/users.acl" >&2
  exit 1
}

mkdir -p "${RUNTIME}/certs"
cp "${CERT_SRC}/ca.crt" "${RUNTIME}/certs/ca.crt"
cp "${CERT_SRC}/server.crt" "${RUNTIME}/certs/server.crt"
cp "${CERT_SRC}/server.key" "${RUNTIME}/certs/server.key"
chmod 0644 "${RUNTIME}/certs/ca.crt" "${RUNTIME}/certs/server.crt"
chmod 0600 "${RUNTIME}/certs/server.key"
cp "${CONF_SRC}/users.acl" "${RUNTIME}/users.acl"
chmod 0600 "${RUNTIME}/users.acl"

# Persist conf references /etc/cache-certs + /etc/valkey/users.acl; rewrite for runtime.
sed \
  -e "s|^tls-cert-file .*|tls-cert-file ${RUNTIME}/certs/server.crt|" \
  -e "s|^tls-key-file .*|tls-key-file ${RUNTIME}/certs/server.key|" \
  -e "s|^tls-ca-cert-file .*|tls-ca-cert-file ${RUNTIME}/certs/ca.crt|" \
  -e "s|^aclfile .*|aclfile ${RUNTIME}/users.acl|" \
  "${CONF_SRC}/valkey.conf" >"${RUNTIME}/valkey.conf"

exec valkey-server "${RUNTIME}/valkey.conf" "$@"
