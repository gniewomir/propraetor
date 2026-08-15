#!/usr/bin/env bash
# Deep Database Component Setup (ADR-0049 / #188 / #189 / #190 / #191 / #232).
# Sourced by Database pre-workloads.sh / post-workloads.sh.
# Standing ensure: TLS interior, admin EnvironmentFile, auth conf (pg_ident
# create-if-missing), Postgres on Service Network dial name `database`.
# Declaration converge: gather Intent-run Requires database:true and publish
# passwordless mTLS bindings (#189); non-claimants unpublished (#190).
# post-workloads drops role/db/client material for Orphan-absent basenames (#191)
# — no re-converge after standing (#232).
#
# Ambient (optional overrides for offline tests):
#   USER_NAME, DATA_ROOT, WORKLOADS_ROOT
# After begin: HOME_DIR / UNIT_DIR / SYSTEMD_USER_DIR via quadlet_user_session_begin.
#
# Args: component_tree [staged_admin_env_src]
# Omitted stage path resolves from the Component Setup handoff root.

_database_setup_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=host-volume-paths-host.sh
source "${_database_setup_lib_dir}/host-volume-paths-host.sh"
# shellcheck source=quadlet-user-session.sh
source "${_database_setup_lib_dir}/quadlet-user-session.sh"
# shellcheck source=component-units-host.sh
source "${_database_setup_lib_dir}/component-units-host.sh"
# shellcheck source=component-handoff-host.sh
source "${_database_setup_lib_dir}/component-handoff-host.sh"
# shellcheck source=component-tls-host.sh
source "${_database_setup_lib_dir}/component-tls-host.sh"
# shellcheck source=database-admin-env-host.sh
source "${_database_setup_lib_dir}/database-admin-env-host.sh"
# shellcheck source=database-auth-conf-host.sh
source "${_database_setup_lib_dir}/database-auth-conf-host.sh"
# shellcheck source=database-fulfill-host.sh
source "${_database_setup_lib_dir}/database-fulfill-host.sh"

# Wait until Postgres accepts connections inside the database-postgres container.
# Covers cold image pull (unit stays "activating"); fails closed as soon as the unit
# is "failed" so a hard start error does not burn the full timeout.
database_wait_ready() {
  local _
  local cname="database-postgres"
  local admin_user=""
  local state=""
  if [[ -f "${ADMIN_ENV:-}" ]]; then
    admin_user="$(database_admin_user_from_env "${ADMIN_ENV}" 2>/dev/null || true)"
  fi
  # Pull timeout inside systemd is 5m; leave headroom for initdb after pull.
  for _ in $(seq 1 360); do
    state="$(quadlet_user systemctl --user show -p ActiveState --value database-postgres.service 2>/dev/null || true)"
    if [[ "${state}" == "failed" ]]; then
      echo "Database: database-postgres.service failed before ready" >&2
      return 1
    fi
    if [[ -n "${admin_user}" ]]; then
      if quadlet_user env "HOME=${HOME_DIR}" bash -c \
        "cd \"\$HOME\" && podman exec ${cname} pg_isready -U $(printf '%q' "${admin_user}") -q" \
        >/dev/null 2>&1; then
        return 0
      fi
    else
      if quadlet_user env "HOME=${HOME_DIR}" bash -c \
        "cd \"\$HOME\" && podman exec ${cname} pg_isready -q" >/dev/null 2>&1; then
        return 0
      fi
    fi
    sleep 1
  done
  echo "Database: Postgres did not become ready (pg_isready)" >&2
  return 1
}

# Standing ensure: units / TLS / admin / auth conf — not Declaration converge.
# Args: component_tree [staged_admin_env_src]
# Omitted stage path resolves from the Component Setup handoff root.
database_standing_ensure() {
  local component_tree="${1:?database_standing_ensure: component tree required}"
  shift
  local staged_admin_env=""

  if [[ $# -gt 0 && "$1" != --* ]]; then
    staged_admin_env="$1"
    shift
  fi
  if [[ $# -gt 0 ]]; then
    echo "database_standing_ensure: unknown argument: $1" >&2
    return 1
  fi

  [[ -n "${staged_admin_env}" ]] || staged_admin_env="$(component_handoff_database_admin_env)"

  USER_NAME="${USER_NAME:-platform}"
  DATA_ROOT="${DATA_ROOT:-$(host_volume_component_persist database)}"
  WORKLOADS_ROOT="${WORKLOADS_ROOT:-$(host_volume_workloads_sot_root)}"
  ADMIN_ENV="${DATA_ROOT}/admin/environment"
  PGDATA_DIR="${DATA_ROOT}/pgdata"
  CLIENTS_DIR="${DATA_ROOT}/clients"

  quadlet_user_session_begin

  mkdir -p "${DATA_ROOT}" "${PGDATA_DIR}" "${CLIENTS_DIR}" "${DATA_ROOT}/admin"

  database_install_admin_env "${staged_admin_env}" || return 1
  component_tls_ensure database "${DATA_ROOT}" || return 1
  # Standing auth: pg_hba always; pg_ident create-if-missing only — converge
  # owns claimant map rows (#232 / mirrors Cache standing ACL preserve).
  database_write_auth_conf || return 1

  component_units_install "${component_tree}" component "$(basename "${component_tree}")" || return 1
  [[ -f "${component_tree}/entrypoint.sh" ]] || {
    echo "Database entrypoint.sh missing at ${component_tree}/entrypoint.sh" >&2
    return 1
  }
  chmod a+x "${component_tree}/entrypoint.sh"

  # TLS/auth leaves: Platform User–owned for rootless mounts.
  # pgdata mount root: mkdir above runs as root; rootless :U must be able to lchown
  # that path or start fails with "operation not permitted". Own the mount point only
  # (non-recursive) — live cluster files stay on subuids after :U; recursive Host
  # chown of a running cluster causes Permission denied / PANIC (ADR-0049 / #188).
  chown -R "${USER_NAME}:${USER_NAME}" "${HOME_DIR}/.config" 2>/dev/null || true
  for leaf in ca server admin conf clients; do
    if [[ -e "${DATA_ROOT}/${leaf}" ]]; then
      chown -R "${USER_NAME}:${USER_NAME}" "${DATA_ROOT}/${leaf}" 2>/dev/null || true
    fi
  done
  chown "${USER_NAME}:${USER_NAME}" "${DATA_ROOT}" 2>/dev/null || true
  chown "${USER_NAME}:${USER_NAME}" "${PGDATA_DIR}"

  quadlet_user_session_reload
  quadlet_user systemctl --user reset-failed \
    database-pod.service database-postgres.service 2>/dev/null || true

  # Always restart so unit/config mounts and :U ownership stay coherent after Setup.
  # Pod becomes active before postgres finishes pull/start; readiness wait covers that.
  quadlet_user systemctl --user restart database-pod.service
  quadlet_user systemctl --user --quiet is-active database-pod.service || {
    echo "Database: database-pod.service is not active" >&2
    quadlet_user systemctl --user status database-pod.service database-postgres.service --no-pager >&2 || true
    return 1
  }

  database_wait_ready || {
    quadlet_user systemctl --user status database-pod.service database-postgres.service --no-pager >&2 || true
    return 1
  }

  # Align live admin SCRAM with staged Environment credentials (initdb is create-once).
  database_sync_admin_password "${ADMIN_ENV}" || return 1
}

# Ordering (#232): standing ensure → Declaration converge (before Workload apps).
database_setup_pre_workloads() {
  local component_tree="${1:?database_setup_pre_workloads: component tree required}"
  local staged_admin_env="${2:-}"
  database_standing_ensure "${component_tree}" "${staged_admin_env}" || return 1
  database_fulfill_declarations || return 1
}

# Ordering (#232): standing ensure → Orphan drop. No Declaration re-converge.
database_setup_post_workloads() {
  local component_tree="${1:?database_setup_post_workloads: component tree required}"
  local staged_admin_env="${2:-}"
  database_standing_ensure "${component_tree}" "${staged_admin_env}" || return 1
  database_drop_absent_fulfillments || return 1
}
