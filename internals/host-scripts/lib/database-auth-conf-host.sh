#!/usr/bin/env bash
# Write Database pg_hba.conf + pg_ident.conf (ADR-0049 / #188 / #189).
# Dual auth: SCRAM for admin role over TLS; cert+verify-full for Workloads via map.
# Expects: DATA_ROOT, ADMIN_ENV. Optional: USER_NAME.

# Map name for Workload cert CN → role (pg_ident + hostssl cert map=).
DATABASE_PG_IDENT_MAP="propraetor"

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
# Workload client certificates (CN → role via pg_ident map ${DATABASE_PG_IDENT_MAP}).
hostssl all             all             0.0.0.0/0               cert clientcert=verify-full map=${DATABASE_PG_IDENT_MAP}
hostssl all             all             ::/0                    cert clientcert=verify-full map=${DATABASE_PG_IDENT_MAP}
EOF

  # Standing: create-if-missing empty map only. Declaration converge rewrites
  # claimant rows — never idle-empty as a restart side effect (#232).
  if [[ ! -f "${ident}" ]]; then
    database_write_pg_ident_file /dev/null
  fi

  chmod 0644 "${hba}" "${ident}"
  if [[ -n "${USER_NAME:-}" ]]; then
    chown -R "${USER_NAME}:${USER_NAME}" "${conf_dir}" 2>/dev/null || true
  fi
}

# Rewrite pg_ident map rows from basenames in file (Intent-run claimants only).
# Non-claimants are omitted so Intent stop unpublish clears live map rows (#190).
database_write_pg_ident_file() {
  local path="${1:?database_write_pg_ident_file: path required}"
  local conf_dir="${DATA_ROOT}/conf"
  local ident="${conf_dir}/pg_ident.conf"
  local basename
  mkdir -p "${conf_dir}"

  {
    printf '%s\n' \
      "# MAPNAME       SYSTEM-USERNAME         PG-USERNAME" \
      "# Database Component pg_ident — Workload cert CNs mapped by Setup gather."
    if [[ -f "${path}" ]]; then
      while IFS= read -r basename; do
        [[ -n "${basename}" ]] || continue
        printf '%s\t%s\t%s\n' "${DATABASE_PG_IDENT_MAP}" "${basename}" "${basename}"
      done <"${path}"
    fi
  } >"${ident}"

  chmod 0644 "${ident}"
  if [[ -n "${USER_NAME:-}" ]]; then
    chown "${USER_NAME}:${USER_NAME}" "${ident}" 2>/dev/null || true
  fi
}
