#!/usr/bin/env bash
# Host write of Valkey config for the Cache Component (ADR-0055 / #221).
# Sourced by Cache Setup. Expects: DATA_ROOT (Cache Persist).
# TLS-only (port 0); no AOF/RDB; small maxmemory + allkeys-lru.

cache_write_valkey_conf() {
  local conf_dir="${DATA_ROOT}/conf"
  local conf_path="${conf_dir}/valkey.conf"
  local acl_path="${conf_dir}/users.acl"

  [[ -n "${DATA_ROOT:-}" ]] || {
    echo "cache_write_valkey_conf: DATA_ROOT is unset" >&2
    return 1
  }
  mkdir -p "${conf_dir}"

  cat >"${conf_path}" <<'EOF'
# Propraetor Cache Component (Valkey engine). Managed by Component Setup.
port 0
tls-port 6379
tls-cert-file /etc/cache-certs/server.crt
tls-key-file /etc/cache-certs/server.key
tls-ca-cert-file /etc/cache-certs/ca.crt
tls-auth-clients yes
tls-auth-clients-user CN
aclfile /etc/valkey/users.acl
dir /tmp
save ""
appendonly no
maxmemory 64mb
maxmemory-policy allkeys-lru
protected-mode no
daemonize no
EOF

  chmod 0644 "${conf_path}"
  [[ -f "${acl_path}" ]] || {
    echo "cache_write_valkey_conf: ACL file missing at ${acl_path}; write ACL first" >&2
    return 1
  }

  if [[ -n "${USER_NAME:-}" ]]; then
    chown "${USER_NAME}:${USER_NAME}" "${conf_path}" 2>/dev/null || true
  fi
}
