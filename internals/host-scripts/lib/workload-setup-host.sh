#!/usr/bin/env bash
# Host Workload Setup apply (ADR-0053 / ADR-0054 / #233).
# Sourced by ensure-workload-host.sh (and operator stage for identity).
#
# Public interface:
#   workload_identity_require NAME
#     Fail closed unless NAME is a single non-hidden path segment and not a
#     reserved Component dial basename (database / cache).
#   workload_setup_apply TREE [ENV_RESOLVED]
#     Project TREE onto the Host Volume owner, fulfill Environment Configuration
#     after materialize, preflight units, commit, apply Intent / env drop-ins,
#     and chown. Callers pass project tree + optional resolved env path —
#     noop / hook / chown / step order stay inside.

_WL_SETUP_HOST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=workload-identity-host.sh
source "${_WL_SETUP_HOST_DIR}/workload-identity-host.sh"
# shellcheck source=host-volume-paths-host.sh
source "${_WL_SETUP_HOST_DIR}/host-volume-paths-host.sh"
# shellcheck source=quadlet-user-session.sh
source "${_WL_SETUP_HOST_DIR}/quadlet-user-session.sh"
# shellcheck source=workload-units-host.sh
source "${_WL_SETUP_HOST_DIR}/workload-units-host.sh"
# shellcheck source=workload-environment-host.sh
source "${_WL_SETUP_HOST_DIR}/workload-environment-host.sh"
# shellcheck source=workload-manifest-host.sh
source "${_WL_SETUP_HOST_DIR}/workload-manifest-host.sh"
# Staged sibling, or in-tree Artifact lib for offline Unit Tests.
_wl_setup_manifest_lib="${_WL_SETUP_HOST_DIR}/manifest.sh"
if [[ ! -f "${_wl_setup_manifest_lib}" ]]; then
  _wl_setup_manifest_lib="${_WL_SETUP_HOST_DIR}/../../lib/artifact/manifest.sh"
fi
# shellcheck source=../../lib/artifact/manifest.sh
source "${_wl_setup_manifest_lib}"
# shellcheck source=workload-project-host.sh
source "${_WL_SETUP_HOST_DIR}/workload-project-host.sh"

# TREE → applied Workload (Host Volume SoT + Intent + Environment Configuration).
# Optional ENV_RESOLVED is the staged resolved EnvironmentFile source (empty → clear).
workload_setup_apply() {
  local tree="${1:?workload_setup_apply: workload tree required}"
  local env_resolved="${2-}"
  local user_name="${PLATFORM_USER:-platform}"
  local manifest="${tree}/manifest.json"
  local wl_name wl_persist sot_tree prev_owned mat_tree systemd_stage

  [[ -d "${tree}" ]] || {
    echo "workload tree missing: ${tree}" >&2
    return 1
  }
  [[ -f "${manifest}" ]] || {
    echo "manifest.json missing in ${tree}" >&2
    return 1
  }

  wl_name="$(basename "${tree}")"
  workload_identity_require "${wl_name}" || return 1

  # Ambient for units / env / quadlet modules (same contract as Component Setup).
  WORKLOADS_ROOT="${WORKLOADS_ROOT:-$(host_volume_workloads_sot_root)}"
  # Nested Persist under this owner (ADR-0054); created by projection when missing.
  wl_persist="$(host_volume_workload_persist "${wl_name}")"
  sot_tree="${WORKLOADS_ROOT}/${wl_name}"

  command -v python3 >/dev/null || {
    echo "python3 required on Host for Workload Manifest parsing" >&2
    return 1
  }

  # Allowlist {intent, description, source} + required Source (ADR-0053 / #200).
  artifact_manifest_validate "${manifest}" || return 1

  local wl_intent
  wl_intent="$(workload_manifest_intent "${manifest}")" || return 1

  if [[ -n "${env_resolved}" ]]; then
    [[ -f "${env_resolved}" ]] || {
      echo "Environment Configuration resolved file missing: ${env_resolved}" >&2
      return 1
    }
  fi

  # Snapshot unit ownership before projection so foreign basename refusal still
  # works when stage_dir is the projected SoT bag (same-inode sync_sot noop).
  prev_owned="$(mktemp "${TMPDIR:-/tmp}/platform-wl-prev-owned.XXXXXX")"
  mat_tree="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/platform-wl-mat.XXXXXX")"
  # shellcheck disable=SC2064  # expand now for this apply's temps
  trap "rm -f '${prev_owned}'; rm -rf '${mat_tree}'" RETURN

  unit_bag_basenames "${sot_tree}/systemd" >"${prev_owned}" || true

  # Session dirs (UNIT_DIR / SYSTEMD_USER_DIR) required for foreign-basename checks.
  USER_NAME="${user_name}"
  quadlet_user_session_begin

  # Materialize → fulfill → units preflight → commit (shared projection module).
  # Preflight before commit refuses Component/cross-Workload collisions without
  # writing colliding systemd/ into Host Volume SoT first.
  workload_materialize_tree "${tree}" "${mat_tree}" || return 1
  environment_configuration_fulfill_after_materialize "${mat_tree}" || return 1
  export WORKLOAD_UNITS_PREV_OWNED="${prev_owned}"
  workload_units_preflight "${wl_name}" "${mat_tree}/systemd" || return 1
  workload_project_commit "${mat_tree}" "${sot_tree}" || return 1
  rm -rf "${mat_tree}"
  mat_tree=""

  systemd_stage="${sot_tree}/systemd"

  # Environment Configuration must run after unit reconcile (drop-ins beside Host
  # units) and before daemon-reload / Intent. Registered as the units-module hook.
  workload_units_before_reload() {
    environment_configuration_apply_or_clear "${wl_name}" "${env_resolved}"
  }

  # Route Declarations stay in Workload SoT only (ADR-0040). Edge gathers.
  # units_apply preflights with pre-projection ownership; sync_sot same-inode noop.
  workload_units_apply "${wl_name}" "${wl_intent}" "${systemd_stage}" || return 1
  unset -f workload_units_before_reload
  unset WORKLOAD_UNITS_PREV_OWNED

  # Cover Host Volume SoT (incl. units synced by apply) and nested Persist.
  chown -R "${user_name}:${user_name}" \
    "${sot_tree}" \
    "${wl_persist}"
  return 0
}
