#!/usr/bin/env bash
# Host-local Workload Setup. Invoked by internals/ensure-workload.sh (not an operator entrypoint).
# Usage: PLATFORM_USER=platform bash ensure-workload-host.sh /path/to/workload-tree
# Workload tree must contain manifest.json; bag may include arbitrary siblings (ADR-0047).
# Identity is the basename of the Workload tree directory.
# Materialize matches Mirror (ADR-0053 / #204) — no second projection rule.
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
# shellcheck source=sync-tree-host.sh
source "${HERE}/sync-tree-host.sh"
# shellcheck source=workload-manifest-host.sh
source "${HERE}/workload-manifest-host.sh"
# shellcheck source=../lib/artifact/manifest.sh
source "${HERE}/manifest.sh"
# shellcheck source=../lib/artifact/binding.sh
source "${HERE}/binding.sh"
# shellcheck source=workload-materialize-host.sh
source "${HERE}/workload-materialize-host.sh"

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

# Nested Persist under this owner (ADR-0054).
WL_PERSIST="$(host_volume_workload_persist "${WL_NAME}")"

command -v python3 >/dev/null || {
  echo "python3 required on Host for Workload Manifest parsing" >&2
  exit 1
}

# Allowlist {intent, description, source} + required Source (ADR-0053 / #200).
# Intent uses the Host Manifest module. Database gather reads Requires (#202).
# Setup must not dual-read retired Manifest keys (ADR-0018).
artifact_manifest_validate "${MANIFEST}" || exit 1

WL_INTENT="$(workload_manifest_intent "${MANIFEST}")" || exit 1

# Environment Configuration: operator stage_for_setup remaps the bag (Binding;
# Requires full-fulfill is Host-side after materialize). Active iff a resolved
# file was staged (SSH adapter). Host full-fulfills Binding vs Artifact Requires
# on the materialized tree and re-runs the containers gate there.
WL_ENV_RESOLVED="${WL_ENV_RESOLVED:-}"
if [[ -n "${WL_ENV_RESOLVED}" ]]; then
  [[ -f "${WL_ENV_RESOLVED}" ]] || {
    echo "Environment Configuration resolved file missing: ${WL_ENV_RESOLVED}" >&2
    exit 1
  }
fi

mkdir -p "${WORKLOADS_ROOT}/${WL_NAME}" "${WL_PERSIST}"

STAGE_UNITS="$(mktemp "${TMPDIR:-/tmp}/platform-stage-units.XXXXXX")"
MAT_TREE="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/platform-wl-mat.XXXXXX")"
trap 'rm -f "${STAGE_UNITS}"; rm -rf "${MAT_TREE}"' EXIT

# Same Host projection as Mirror (ADR-0053 / #204).
workload_materialize_tree "${TREE}" "${MAT_TREE}" || exit 1
environment_configuration_fulfill_materialized "${MAT_TREE}" || exit 1

SYSTEMD_STAGE="${MAT_TREE}/systemd"

workload_quadlet_sot_basenames "${SYSTEMD_STAGE}" | LC_ALL=C sort -u >"${STAGE_UNITS}"

quadlet_user_session_begin

# Environment Configuration must run after unit reconcile (drop-ins beside Host
# units) and before daemon-reload / Intent. Registered as the units-module hook.
workload_units_before_reload() {
  environment_configuration_apply_resolved "${WL_NAME}" "${WL_ENV_RESOLVED}"
}

# Noop when materialize result equals Host Volume SoT (ADR-0033). Intent run still
# converges if required unit files are missing (e.g. Host recreated).
SOT_TREE="${WORKLOADS_ROOT}/${WL_NAME}"
if [[ -f "${SOT_TREE}/manifest.json" ]] && diff -rq "${MAT_TREE}" "${SOT_TREE}" >/dev/null 2>&1; then
  units_ok=1
  if [[ "${WL_INTENT}" == "run" ]]; then
    while IFS= read -r base; do
      [[ -n "${base}" ]] || continue
      if ! workload_unit_basename_exists_on_host "${base}"; then
        units_ok=0
        break
      fi
    done <"${STAGE_UNITS}"
  fi
  if [[ "${units_ok}" -eq 1 ]]; then
    # Env refresh/removal must not be skipped by SoT noop (ADR-0035); Intent still applied.
    workload_units_apply "${WL_NAME}" "${WL_INTENT}" "${SYSTEMD_STAGE}" || exit 1
    unset -f workload_units_before_reload
    echo "Workload Setup noop: '${WL_NAME}' already matches Host Volume SoT"
    exit 0
  fi
fi

# Refuse foreign / invalid units before mutating Host Volume SoT.
workload_units_preflight "${WL_NAME}" "${SYSTEMD_STAGE}" || exit 1

# Same materialize projection as Mirror (ADR-0053); unit apply then syncs systemd/.
sync_tree_inplace "${MAT_TREE}" "${WORKLOADS_ROOT}/${WL_NAME}" || exit 1

# Route Declarations stay in Workload SoT only (ADR-0040). Edge Component Setup gathers.
workload_units_apply "${WL_NAME}" "${WL_INTENT}" "${SYSTEMD_STAGE}" || exit 1
unset -f workload_units_before_reload

# Cover Host Volume SoT (incl. units synced by apply) and nested Persist.
chown -R "${USER_NAME}:${USER_NAME}" \
  "${WORKLOADS_ROOT}/${WL_NAME}" \
  "${WL_PERSIST}"
