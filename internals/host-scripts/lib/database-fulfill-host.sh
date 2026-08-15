#!/usr/bin/env bash
# Database Declaration adapter on shared Declaration converge (ADR-0055 / #231).
# Intent-run + Requires database:true → role/db/client cert + published binding.
# Non-claimants → unpublish binding; retain role/db/clients until Orphan Reap.
# Orphan Reap (SoT gone) → drop role/db/clients + clear projection in post-workloads.
# Sourced by Database Setup. Expects ambient after database_setup begin:
#   DATA_ROOT, CLIENTS_DIR, ADMIN_ENV, HOME_DIR, UNIT_DIR, USER_NAME, WORKLOADS_ROOT
# Requires: quadlet_user, component_tls_ensure_client, database_write_pg_ident_file,
#           database_admin_user_from_env, declaration converge, artifact_requires_database.

_database_fulfill_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=declaration-converge-host.sh
source "${_database_fulfill_lib_dir}/declaration-converge-host.sh"
# Host Volume ships a copy of internals/lib/artifact/requires.sh beside this file
# (ensure-fabric / ensure-components). Unit Tests source this file in-tree.
_requires_lib="${_database_fulfill_lib_dir}/requires.sh"
if [[ ! -f "${_requires_lib}" ]]; then
  _requires_lib="${_database_fulfill_lib_dir}/../../lib/artifact/requires.sh"
fi
if [[ ! -f "${_requires_lib}" ]]; then
  echo "database-fulfill-host: Requires library missing" >&2
  return 1
fi
# shellcheck source=../../lib/artifact/requires.sh
source "${_requires_lib}"

_DATABASE_BINDING_KIND=database
_DATABASE_DROPIN_LEAF=50-platform-database.conf
_DATABASE_MOUNT_ROOT=/etc/platform-database

# Platform User path for one Workload's published Database binding directory.
workload_database_binding_dir() {
  local wl_name="${1:?workload name required}"
  declaration_binding_dir "${wl_name}" "${_DATABASE_BINDING_KIND}"
}

workload_database_dropin_path() {
  local container_base="${1:?container basename required}"
  declaration_dropin_path "${container_base}" "${_DATABASE_DROPIN_LEAF}"
}

# Create-if-missing role + database named by basename (owner = role).
# Basename is a Workload identity (single path segment); quoted as a PG identifier.
database_ensure_role_and_db() {
  local basename="${1:?database_ensure_role_and_db: basename required}"
  local admin_user
  local role_exists db_exists
  admin_user="$(database_admin_user_from_env "${ADMIN_ENV}")" || return 1

  role_exists="$(
    quadlet_user env "HOME=${HOME_DIR}" bash -c \
      "cd \"\$HOME\" && podman exec database-postgres \
        psql -v ON_ERROR_STOP=1 -U $(printf '%q' "${admin_user}") -d postgres -tAc \
        $(printf '%q' "SELECT 1 FROM pg_roles WHERE rolname = '${basename}'")" \
      2>/dev/null | tr -d '[:space:]' || true
  )"
  if [[ "${role_exists}" != "1" ]]; then
    quadlet_user env "HOME=${HOME_DIR}" bash -c \
      "cd \"\$HOME\" && podman exec database-postgres \
        psql -v ON_ERROR_STOP=1 -U $(printf '%q' "${admin_user}") -d postgres -c \
        $(printf '%q' "CREATE ROLE \"${basename}\" LOGIN")" \
      || return 1
  fi

  db_exists="$(
    quadlet_user env "HOME=${HOME_DIR}" bash -c \
      "cd \"\$HOME\" && podman exec database-postgres \
        psql -v ON_ERROR_STOP=1 -U $(printf '%q' "${admin_user}") -d postgres -tAc \
        $(printf '%q' "SELECT 1 FROM pg_database WHERE datname = '${basename}'")" \
      2>/dev/null | tr -d '[:space:]' || true
  )"
  if [[ "${db_exists}" != "1" ]]; then
    quadlet_user env "HOME=${HOME_DIR}" bash -c \
      "cd \"\$HOME\" && podman exec database-postgres \
        psql -v ON_ERROR_STOP=1 -U $(printf '%q' "${admin_user}") -d postgres -c \
        $(printf '%q' "CREATE DATABASE \"${basename}\" OWNER \"${basename}\"")" \
      || return 1
  fi

  # No cross-Workload grants (ADR-0049 / #190): Postgres defaults CONNECT to PUBLIC.
  quadlet_user env "HOME=${HOME_DIR}" bash -c \
    "cd \"\$HOME\" && podman exec database-postgres \
      psql -v ON_ERROR_STOP=1 -U $(printf '%q' "${admin_user}") -d postgres -c \
      $(printf '%q' "REVOKE CONNECT ON DATABASE \"${basename}\" FROM PUBLIC")" \
    || return 1
}

_database_write_binding_env() {
  local env_path="${1:?}"
  local wl_name="${2:?}"
  local mount_root="${3:?}"
  cat >"${env_path}" <<EOF
PGHOST=database
PGPORT=5432
PGUSER=${wl_name}
PGDATABASE=${wl_name}
PGSSLMODE=verify-full
PGSSLROOTCERT=${mount_root}/ca.crt
PGSSLCERT=${mount_root}/client.crt
PGSSLKEY=${mount_root}/client.key
EOF
  chmod 0600 "${env_path}"
}

# Publish binding + Setup-owned Quadlet drop-in for one Workload.
database_publish_binding() {
  local wl_name="${1:?database_publish_binding: workload name required}"
  declaration_publish_mtls_binding \
    "${wl_name}" \
    "${_DATABASE_BINDING_KIND}" \
    "${_DATABASE_DROPIN_LEAF}" \
    "${_DATABASE_MOUNT_ROOT}" \
    _database_write_binding_env
}

# Clear published binding + Setup-owned drop-ins for one Workload (Intent stop).
# Retains Host Volume client material, role, and database until Orphan Reap (#191).
database_unpublish_binding() {
  local wl_name="${1:?database_unpublish_binding: workload name required}"
  declaration_unpublish_mtls_binding \
    "${wl_name}" \
    "${_DATABASE_BINDING_KIND}" \
    "${_DATABASE_DROPIN_LEAF}"
}

# Drop Postgres role + database named by basename (terminate backends first).
database_drop_role_and_db() {
  local basename="${1:?database_drop_role_and_db: basename required}"
  local admin_user
  admin_user="$(database_admin_user_from_env "${ADMIN_ENV}")" || return 1

  quadlet_user env "HOME=${HOME_DIR}" bash -c \
    "cd \"\$HOME\" && podman exec database-postgres \
      psql -v ON_ERROR_STOP=1 -U $(printf '%q' "${admin_user}") -d postgres -c \
      $(printf '%q' "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${basename}' AND pid <> pg_backend_pid();")" \
    >/dev/null || true

  quadlet_user env "HOME=${HOME_DIR}" bash -c \
    "cd \"\$HOME\" && podman exec database-postgres \
      psql -v ON_ERROR_STOP=1 -U $(printf '%q' "${admin_user}") -d postgres -c \
      $(printf '%q' "DROP DATABASE IF EXISTS \"${basename}\"")" \
    || return 1

  quadlet_user env "HOME=${HOME_DIR}" bash -c \
    "cd \"\$HOME\" && podman exec database-postgres \
      psql -v ON_ERROR_STOP=1 -U $(printf '%q' "${admin_user}") -d postgres -c \
      $(printf '%q' "DROP ROLE IF EXISTS \"${basename}\"")" \
    || return 1
}

# Full drop for one basename: DROP role/db, then unpublish and remove durable clients.
# Postgres drop runs before rm clients so a failed DROP remains selectable on retry (#191).
database_drop_fulfillment() {
  local wl_name="${1:?database_drop_fulfillment: workload name required}"
  local client_dir="${DATA_ROOT}/clients/${wl_name}"

  database_drop_role_and_db "${wl_name}" || return 1
  database_unpublish_binding "${wl_name}" || return 1
  rm -rf "${client_dir}"
  echo "Database: dropped fulfillment for Workload '${wl_name}'" >&2
}

# Print client basenames under CLIENTS_DIR whose Workload SoT Manifest is gone.
database_absent_client_basenames() {
  declaration_absent_client_basenames "$@"
}

# post-workloads: drop role/db/clients + clear projection for Orphan-absent basenames.
database_drop_absent_fulfillments() {
  local workloads_root="${1:-${WORKLOADS_ROOT-}}"
  local clients_dir="${CLIENTS_DIR:-${DATA_ROOT}/clients}"

  if [[ -z "${workloads_root}" ]]; then
    echo "database_drop_absent_fulfillments: workloads root required" >&2
    return 1
  fi

  declaration_drop_absent_fulfillments \
    "${workloads_root}" \
    "${clients_dir}" \
    database_drop_fulfillment
}

# Reload Postgres config after pg_ident changes (bind-mounted conf).
database_reload_conf() {
  local admin_user
  admin_user="$(database_admin_user_from_env "${ADMIN_ENV}")" || return 1
  quadlet_user env "HOME=${HOME_DIR}" bash -c \
    "cd \"\$HOME\" && podman exec database-postgres \
      psql -v ON_ERROR_STOP=1 -U $(printf '%q' "${admin_user}") -d postgres -c \
      'SELECT pg_reload_conf();'" \
    >/dev/null || {
    echo "Database: pg_reload_conf failed" >&2
    return 1
  }
}

# Print 1 when the Workload tree is Intent-run and Requires database: true, else 0.
# Fail closed on invalid Manifest Intent or Requires (missing/invalid requires.json).
# Manifest does not participate (ADR-0018 / ADR-0053 / #202).
database_workload_is_run_claimant() {
  local wl_dir="${1:?database_workload_is_run_claimant: workload tree required}"
  declaration_workload_is_run_claimant "${wl_dir}" artifact_requires_database
}

# Rewrite pg_ident from claimants, then reload Postgres.
_database_prepare_claimants() {
  local sorted_file="${1:?}"

  database_write_pg_ident_file "${sorted_file}" || return 1
  database_reload_conf || return 1
}

# Ensure client cert + role/db, then publish binding for one claimant.
_database_fulfill_one() {
  local wl_name="${1:?}"

  component_tls_ensure_client database "${DATA_ROOT}" "${wl_name}" || return 1
  database_ensure_role_and_db "${wl_name}" || return 1
  database_publish_binding "${wl_name}" || return 1
}

# Gather Intent-run Requires database:true claimants; create role/db/cert + publish.
# Non-claimants: unpublish binding only; role/database/client material until Orphan Reap.
database_fulfill_declarations() {
  local workloads_root="${1:-${WORKLOADS_ROOT-}}"

  if [[ -z "${workloads_root}" ]]; then
    echo "database_fulfill_declarations: workloads root required" >&2
    return 1
  fi

  declaration_converge_claims \
    "${workloads_root}" \
    "Database" \
    "database" \
    database_workload_is_run_claimant \
    "" \
    _database_prepare_claimants \
    _database_fulfill_one \
    database_unpublish_binding \
    workload_database_binding_dir
}
