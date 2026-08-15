#!/usr/bin/env bash
# Deep Cache Component Setup (ADR-0055 / #221 / #222 / #224 / #225).
# Sourced by Cache pre-workloads.sh / post-workloads.sh.
# Standing Component: TLS interior, ACL (default off + admin), admin client cert,
# Valkey on Service Network dial name `cache`, idle allowed with zero claimants.
# pre/post gather Intent-run Requires cache:true, publish bindings, disable stopped.
# post-workloads also drops Orphan-absent fulfillments (DELUSER, clients, prefix keys).
#
# Ambient (optional overrides for offline tests):
#   USER_NAME, DATA_ROOT, WORKLOADS_ROOT
# After begin: HOME_DIR / UNIT_DIR / SYSTEMD_USER_DIR via quadlet_user_session_begin.
#
# Args: component_tree [staged_admin_env_src]
# Omitted stage path resolves from the Component Setup handoff root.

_cache_setup_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=host-volume-paths-host.sh
source "${_cache_setup_lib_dir}/host-volume-paths-host.sh"
# shellcheck source=quadlet-user-session.sh
source "${_cache_setup_lib_dir}/quadlet-user-session.sh"
# shellcheck source=component-units-host.sh
source "${_cache_setup_lib_dir}/component-units-host.sh"
# shellcheck source=component-handoff-host.sh
source "${_cache_setup_lib_dir}/component-handoff-host.sh"
# shellcheck source=component-tls-host.sh
source "${_cache_setup_lib_dir}/component-tls-host.sh"
# shellcheck source=cache-admin-env-host.sh
source "${_cache_setup_lib_dir}/cache-admin-env-host.sh"
# shellcheck source=cache-conf-host.sh
source "${_cache_setup_lib_dir}/cache-conf-host.sh"
# shellcheck source=cache-fulfill-host.sh
source "${_cache_setup_lib_dir}/cache-fulfill-host.sh"

# Wait until Valkey accepts TLS PING inside the cache-valkey container.
# Covers cold image pull; fails closed as soon as the unit is "failed".
cache_wait_ready() {
  local _
  local cname="cache-valkey"
  local admin_user=""
  local admin_pass=""
  local state=""
  local admin_env="${ADMIN_ENV:-}"
  local line

  if [[ -f "${admin_env}" ]]; then
    admin_user="$(cache_admin_user_from_env "${admin_env}" 2>/dev/null || true)"
    line="$(grep -E '^CACHE_ADMIN_PASSWORD=' "${admin_env}" | head -n1)" || true
    admin_pass="${line#CACHE_ADMIN_PASSWORD=}"
  fi
  [[ -n "${admin_user}" && -n "${admin_pass}" ]] || {
    echo "Cache: admin credentials unavailable for readiness check" >&2
    return 1
  }

  for _ in $(seq 1 360); do
    state="$(quadlet_user systemctl --user show -p ActiveState --value cache-valkey.service 2>/dev/null || true)"
    if [[ "${state}" == "failed" ]]; then
      echo "Cache: cache-valkey.service failed before ready" >&2
      return 1
    fi
    if quadlet_user env "HOME=${HOME_DIR}" \
      "CACHE_READY_USER=${admin_user}" "CACHE_READY_PASS=${admin_pass}" bash -c \
      "cd \"\$HOME\" && podman exec \
        -e CACHE_READY_USER -e CACHE_READY_PASS \
        ${cname} \
        valkey-cli --tls \
          --cacert /etc/cache-certs/ca.crt \
          --cert /etc/cache-certs/admin.crt \
          --key /etc/cache-certs/admin.key \
          --user \"\$CACHE_READY_USER\" \
          -a \"\$CACHE_READY_PASS\" \
          PING" 2>/dev/null | grep -qx 'PONG'; then
      return 0
    fi
    sleep 1
  done
  echo "Cache: Valkey did not become ready (TLS PING)" >&2
  return 1
}

# Deep Cache Setup success: units active + Valkey ready on Service Network.
# Args: component_tree [staged_admin_env_src]
cache_setup() {
  local component_tree="${1:?cache_setup: component tree required}"
  shift
  local staged_admin_env=""
  local admin_user=""

  if [[ $# -gt 0 && "$1" != --* ]]; then
    staged_admin_env="$1"
    shift
  fi
  if [[ $# -gt 0 ]]; then
    echo "cache_setup: unknown argument: $1" >&2
    return 1
  fi

  [[ -n "${staged_admin_env}" ]] || staged_admin_env="$(component_handoff_cache_admin_env)"

  USER_NAME="${USER_NAME:-platform}"
  DATA_ROOT="${DATA_ROOT:-$(host_volume_component_persist cache)}"
  WORKLOADS_ROOT="${WORKLOADS_ROOT:-$(host_volume_workloads_sot_root)}"
  ADMIN_ENV="${DATA_ROOT}/admin/environment"

  quadlet_user_session_begin

  mkdir -p "${DATA_ROOT}" "${DATA_ROOT}/admin" "${DATA_ROOT}/conf" "${DATA_ROOT}/clients"

  cache_install_admin_env "${staged_admin_env}" || return 1
  component_tls_ensure cache "${DATA_ROOT}" || return 1
  admin_user="$(cache_admin_user_from_env "${ADMIN_ENV}")" || return 1
  component_tls_ensure_admin_client cache "${DATA_ROOT}" "${admin_user}" || return 1
  cache_write_acl_file "${ADMIN_ENV}" || return 1
  cache_write_valkey_conf || return 1

  component_units_install "${component_tree}" component "$(basename "${component_tree}")" || return 1
  [[ -f "${component_tree}/entrypoint.sh" ]] || {
    echo "Cache entrypoint.sh missing at ${component_tree}/entrypoint.sh" >&2
    return 1
  }
  chmod a+x "${component_tree}/entrypoint.sh"

  chown -R "${USER_NAME}:${USER_NAME}" "${HOME_DIR}/.config" 2>/dev/null || true
  for leaf in ca server admin conf clients; do
    if [[ -e "${DATA_ROOT}/${leaf}" ]]; then
      chown -R "${USER_NAME}:${USER_NAME}" "${DATA_ROOT}/${leaf}" 2>/dev/null || true
    fi
  done
  chown "${USER_NAME}:${USER_NAME}" "${DATA_ROOT}" 2>/dev/null || true

  quadlet_user_session_reload
  quadlet_user systemctl --user reset-failed \
    cache-pod.service cache-valkey.service 2>/dev/null || true

  quadlet_user systemctl --user restart cache-pod.service
  quadlet_user systemctl --user --quiet is-active cache-pod.service || {
    echo "Cache: cache-pod.service is not active" >&2
    quadlet_user systemctl --user status cache-pod.service cache-valkey.service --no-pager >&2 || true
    return 1
  }

  cache_wait_ready || {
    quadlet_user systemctl --user status cache-pod.service cache-valkey.service --no-pager >&2 || true
    return 1
  }
}

# Standing ensure + Declaration fulfill/publish before Workload apps start.
cache_setup_pre_workloads() {
  local component_tree="${1:?cache_setup_pre_workloads: component tree required}"
  local staged_admin_env="${2:-}"
  cache_setup "${component_tree}" "${staged_admin_env}" || return 1
  cache_fulfill_declarations || return 1
}

# Standing ensure + Orphan drop + re-fulfill after Workloads (#225).
# Drop runs before fulfill so ACL rewrite omits absent basenames; re-fulfill
# keeps Intent-run ACL users enabled after standing ACL rewrite/restart.
cache_setup_post_workloads() {
  local component_tree="${1:?cache_setup_post_workloads: component tree required}"
  local staged_admin_env="${2:-}"
  cache_setup "${component_tree}" "${staged_admin_env}" || return 1
  cache_drop_absent_fulfillments || return 1
  cache_fulfill_declarations || return 1
}
