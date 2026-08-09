#!/usr/bin/env bash
# Write Database pg_hba.conf + empty pg_ident.conf (ADR-0049 / #188).
# Dual auth: SCRAM for admin role over TLS; cert+verify-full for Workloads.
# Expects: DATA_ROOT, ADMIN_ENV. Optional: USER_NAME.

database_write_auth_conf() {
  local conf_dir="${DATA_ROOT}/conf"
  local hba="${conf_dir}/pg_hba.conf"
  local ident="${conf_dir}/pg_ident.conf"
  local admin_user

  admin_user="$(database_admin_user_from_env "${ADMIN_ENV}")" || return 1
  mkdir -p "${conf_dir}"

  cat >"${hba}" <<EOF
# TYPE  DATABASE        USER            ADDRESS                 METHOD
# Database Component (ADR-0049) — managed by Database Setup; do not edit.
# local trust: required for official image initdb / local maintenance inside the container.
local   all             all                                     trust
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
# Admin SCRAM over TLS (Database admin credentials).
hostssl all             ${admin_user}   0.0.0.0/0               scram-sha-256
hostssl all             ${admin_user}   ::/0                    scram-sha-256
# Workload client certificates (CN → role via pg_ident; gather fills map later).
hostssl all             all             0.0.0.0/0               cert clientcert=verify-full
hostssl all             all             ::/0                    cert clientcert=verify-full
EOF

  if [[ ! -f "${ident}" ]]; then
    cat >"${ident}" <<'EOF'
# MAPNAME       SYSTEM-USERNAME         PG-USERNAME
# Database Component pg_ident — Workload cert CNs mapped by Setup gather.
EOF
  fi

  chmod 0644 "${hba}" "${ident}"
  if [[ -n "${USER_NAME:-}" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "${conf_dir}" 2>/dev/null || true
  fi
}
