#!/usr/bin/env bash
# Host-local Environment Configuration install / clear (ADR-0035 / #128 / #132).
# Sourced by ensure-workload-host, purge-trash-host, purge-orphans-host, and the operator module.
# Requires: HOME_DIR, UNIT_DIR, USER_NAME, WORKLOADS_ROOT (after quadlet_user_session_begin).
#
# Module Host half (Setup/Purge interface):
#   environment_configuration_install_host WL_NAME RESOLVED_SRC
#     RESOLVED_SRC empty → remove EnvironmentFile tree + Setup-owned env drop-ins
#     RESOLVED_SRC set  → install EnvironmentFile + Setup-owned drop-ins for each
#                         SoT quadlets/*.container (EnvironmentFile= path only)
#     Container gate is owned by environment_configuration_prepare (once).
#   environment_configuration_clear WL_NAME
#     Purge / omit clear path.
#
# Path helpers (install layout; not the Setup/Purge contract surface):
#   workload_environment_path / workload_environment_dropin_path

workload_environment_path() {
  local wl_name="${1:?workload name required}"
  printf '%s/.config/platform/workloads/%s/environment\n' "${HOME_DIR}" "${wl_name}"
}

workload_environment_dropin_path() {
  local container_base="${1:?container basename required}"
  # container_base includes .container suffix, e.g. app.container
  printf '%s/%s.d/50-platform-environment.conf\n' "${UNIT_DIR}" "${container_base}"
}

workload_environment_remove_dropins_for_dir() {
  local quadlets_dir="${1:-}"
  local base dropin_path dropin_dir
  [[ -d "${quadlets_dir}" ]] || return 0
  for base in "${quadlets_dir}"/*.container; do
    [[ -f "${base}" ]] || continue
    base="$(basename "${base}")"
    dropin_path="$(workload_environment_dropin_path "${base}")"
    dropin_dir="$(dirname "${dropin_path}")"
    rm -f "${dropin_path}"
    if [[ -d "${dropin_dir}" ]] && [[ -z "$(ls -A "${dropin_dir}" 2>/dev/null || true)" ]]; then
      rmdir "${dropin_dir}" 2>/dev/null || true
    fi
  done
}

environment_configuration_install_host() {
  local wl_name="${1:?workload name required}"
  local resolved_src="${2:-}"
  local env_path dropin_path base dest_dir sot_quadlets

  env_path="$(workload_environment_path "${wl_name}")"
  dest_dir="$(dirname "${env_path}")"
  sot_quadlets="${WORKLOADS_ROOT}/${wl_name}/quadlets"

  if [[ -z "${resolved_src}" ]]; then
    workload_environment_remove_dropins_for_dir "${sot_quadlets}"
    # Remove only the EnvironmentFile — sibling Database bindings live under
    # the same Platform User Workload tree (ADR-0049 / #189).
    rm -f "${env_path}"
    if [[ -d "${dest_dir}" ]] && [[ -z "$(ls -A "${dest_dir}" 2>/dev/null || true)" ]]; then
      rmdir "${dest_dir}" 2>/dev/null || true
    fi
    return 0
  fi

  [[ -f "${resolved_src}" ]] || {
    echo "Environment Configuration resolved file missing: ${resolved_src}" >&2
    return 1
  }

  mkdir -p "${dest_dir}"
  install -m 0600 "${resolved_src}" "${env_path}"
  chown -R "${USER_NAME}:${USER_NAME}" "${dest_dir}" 2>/dev/null || true

  for base in "${sot_quadlets}"/*.container; do
    [[ -f "${base}" ]] || continue
    base="$(basename "${base}")"
    dropin_path="$(workload_environment_dropin_path "${base}")"
    mkdir -p "$(dirname "${dropin_path}")"
    cat >"${dropin_path}" <<EOF
[Container]
EnvironmentFile=${env_path}
EOF
    chown -R "${USER_NAME}:${USER_NAME}" "$(dirname "${dropin_path}")" 2>/dev/null || true
  done
  return 0
}

environment_configuration_clear() {
  local wl_name="${1:?workload name required}"
  environment_configuration_install_host "${wl_name}" ""
}

# Host half after SSH staging: empty/unset RESOLVED_SRC → clear; else install.
environment_configuration_apply_resolved() {
  local wl_name="${1:?workload name required}"
  local resolved_src="${2:-}"
  if [[ -n "${resolved_src}" ]]; then
    environment_configuration_install_host "${wl_name}" "${resolved_src}"
  else
    environment_configuration_clear "${wl_name}"
  fi
}
