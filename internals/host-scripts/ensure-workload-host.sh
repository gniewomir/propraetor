#!/usr/bin/env bash
# Host-local Workload Setup. Invoked by internals/ensure-workload.sh (not an operator entrypoint).
# Usage: PLATFORM_USER=platform bash ensure-workload-host.sh /path/to/workload-tree
# Workload tree must contain manifest.json; bag may include arbitrary siblings (ADR-0047).
# Identity is the basename of the Workload tree directory.
# Projects through the shared Host Workload module (materialize → units
# preflight → commit) before Intent / Environment Configuration apply /
# units reconcile (ADR-0053 / ADR-0054 / #204 / #228).
# Does not build ACME want-list, claim hostnames, or start ACME (ADR-0023).
set -euo pipefail

TREE="${1:?workload tree required}"
USER_NAME="${PLATFORM_USER:-platform}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${TREE}/manifest.json"

# Staged payload beside this script. No Host Volume dual-read (ADR-0018).
# shellcheck source=host-volume-paths-host.sh
source "${HERE}/host-volume-paths-host.sh"
# shellcheck source=quadlet-user-session.sh
source "${HERE}/quadlet-user-session.sh"
# shellcheck source=workload-units-host.sh
source "${HERE}/workload-units-host.sh"
# shellcheck source=workload-environment-host.sh
source "${HERE}/workload-environment-host.sh"
# shellcheck source=workload-manifest-host.sh
source "${HERE}/workload-manifest-host.sh"
# shellcheck source=../lib/artifact/manifest.sh
source "${HERE}/manifest.sh"
# shellcheck source=workload-project-host.sh
source "${HERE}/workload-project-host.sh"

WORKLOADS_ROOT="$(host_volume_workloads_sot_root)"

[[ -d "${TREE}" ]] || {
  echo "workload tree missing: ${TREE}" >&2
  exit 1
}
[[ -f "${MANIFEST}" ]] || {
  echo "manifest.json missing in ${TREE}" >&2
  exit 1
}

WL_NAME="$(basename "${TREE}")"
if [[ -z "${WL_NAME}" || "${WL_NAME}" == "." || "${WL_NAME}" == ".." ]] ||
  [[ "${WL_NAME}" == */* ]] || [[ "${WL_NAME}" =~ [[:space:]] ]]; then
  echo "workload identity (directory basename) must be a single path segment: '${WL_NAME}'" >&2
  exit 1
fi
# Service Network dial name for the Database Component (ADR-0049 / #188).
if [[ "${WL_NAME}" == "database" ]]; then
  echo "workload basename 'database' is reserved for the Database Component dial identity" >&2
  exit 1
fi
# Service Network dial name for the Cache Component (ADR-0055 / #221).
if [[ "${WL_NAME}" == "cache" ]]; then
  echo "workload basename 'cache' is reserved for the Cache Component dial identity" >&2
  exit 1
fi

# Nested Persist under this owner (ADR-0054); created by projection when missing.
WL_PERSIST="$(host_volume_workload_persist "${WL_NAME}")"
SOT_TREE="${WORKLOADS_ROOT}/${WL_NAME}"

command -v python3 >/dev/null || {
  echo "python3 required on Host for Workload Manifest parsing" >&2
  exit 1
}

# Allowlist {intent, description, source} + required Source (ADR-0053 / #200).
# Intent uses the Host Manifest module. Database gather reads Requires (#202).
# Setup must not dual-read retired Manifest keys (ADR-0018).
artifact_manifest_validate "${MANIFEST}" || exit 1

WL_INTENT="$(workload_manifest_intent "${MANIFEST}")" || exit 1

# Environment Configuration: operator stage remaps the bag; Host
# fulfill-after-materialize full-fulfills Binding vs Artifact Requires; then
# apply-or-clear installs or clears from the staged resolved file (empty → clear).
WL_ENV_RESOLVED="${WL_ENV_RESOLVED:-}"
if [[ -n "${WL_ENV_RESOLVED}" ]]; then
  [[ -f "${WL_ENV_RESOLVED}" ]] || {
    echo "Environment Configuration resolved file missing: ${WL_ENV_RESOLVED}" >&2
    exit 1
  }
fi

# Snapshot unit ownership before projection so foreign basename refusal still
# works when stage_dir is the projected SoT bag (same-inode sync_sot noop).
PREV_OWNED="$(mktemp "${TMPDIR:-/tmp}/platform-wl-prev-owned.XXXXXX")"
MAT_TREE="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/platform-wl-mat.XXXXXX")"
trap 'rm -f "${PREV_OWNED}"; rm -rf "${MAT_TREE}"' EXIT
unit_bag_basenames "${SOT_TREE}/systemd" >"${PREV_OWNED}" || true

# Session dirs (UNIT_DIR / SYSTEMD_USER_DIR) required for foreign-basename checks.
quadlet_user_session_begin

# Materialize → fulfill → units preflight → commit (shared projection module).
# Preflight before commit refuses Component/cross-Workload collisions without
# writing colliding systemd/ into Host Volume SoT first.
workload_materialize_tree "${TREE}" "${MAT_TREE}" || exit 1
environment_configuration_fulfill_after_materialize "${MAT_TREE}" || exit 1
export WORKLOAD_UNITS_PREV_OWNED="${PREV_OWNED}"
workload_units_preflight "${WL_NAME}" "${MAT_TREE}/systemd" || exit 1
workload_project_commit "${MAT_TREE}" "${SOT_TREE}" || exit 1
rm -rf "${MAT_TREE}"

SYSTEMD_STAGE="${SOT_TREE}/systemd"

# Environment Configuration must run after unit reconcile (drop-ins beside Host
# units) and before daemon-reload / Intent. Registered as the units-module hook.
workload_units_before_reload() {
  environment_configuration_apply_or_clear "${WL_NAME}" "${WL_ENV_RESOLVED}"
}

# Route Declarations stay in Workload SoT only (ADR-0040). Edge Component Setup gathers.
# units_apply preflights with pre-projection ownership; sync_sot same-inode noop.
workload_units_apply "${WL_NAME}" "${WL_INTENT}" "${SYSTEMD_STAGE}" || exit 1
unset -f workload_units_before_reload
unset WORKLOAD_UNITS_PREV_OWNED

# Cover Host Volume SoT (incl. units synced by apply) and nested Persist.
chown -R "${USER_NAME}:${USER_NAME}" \
  "${SOT_TREE}" \
  "${WL_PERSIST}"
