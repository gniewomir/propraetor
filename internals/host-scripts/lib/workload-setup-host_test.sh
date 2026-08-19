#!/usr/bin/env bash
# Unit tests: Host Workload Setup apply ambient contract (#233 follow-up).
# Seam: workload_setup_apply — must publish WORKLOADS_ROOT for units/env modules.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=workload-setup-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/workload-setup-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/wl-setup-apply.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

TREE="${TMP}/demo"
mkdir -p "${TREE}/systemd"
cat >"${TREE}/manifest.json" <<'EOF'
{ "intent": "run", "source": "internal" }
EOF
printf '[Container]\nImage=localhost/demo\n' >"${TREE}/systemd/demo.container"
printf '{}\n' >"${TREE}/provides.json"
printf '{ "database": false, "cache": false }\n' >"${TREE}/requires.json"

host_volume_workloads_sot_root() { printf '%s\n' "${TMP}/workloads"; }
host_volume_workload_persist() { printf '%s\n' "${TMP}/persist/${1:?}"; }
artifact_manifest_validate() { return 0; }
workload_manifest_intent() { printf 'run\n'; }
quadlet_user_session_begin() {
  UNIT_DIR="${TMP}/unit"
  SYSTEMD_USER_DIR="${TMP}/systemd-user"
  mkdir -p "${UNIT_DIR}" "${SYSTEMD_USER_DIR}"
}
unit_bag_basenames() { return 0; }
workload_materialize_tree() {
  mkdir -p "${2:?}/systemd"
  cp -R "${1:?}/." "${2}/"
}
environment_configuration_fulfill_after_materialize() { return 0; }
workload_project_commit() {
  mkdir -p "${2:?}"
  cp -R "${1:?}/." "${2}/"
}
environment_configuration_apply_or_clear() { return 0; }

PREFLIGHT_SAW_ROOT=0
workload_units_preflight() {
  # Same failure mode as Host: set -u + ambient WORKLOADS_ROOT for tree_hint.
  : "${WORKLOADS_ROOT:?WORKLOADS_ROOT must be set before units preflight}"
  [[ "${WORKLOADS_ROOT}" == "${TMP}/workloads" ]] \
    || fail "WORKLOADS_ROOT must be Host Volume SoT root (got '${WORKLOADS_ROOT}')"
  PREFLIGHT_SAW_ROOT=1
  return 0
}
workload_units_apply() {
  : "${WORKLOADS_ROOT:?WORKLOADS_ROOT must remain set for units apply}"
  return 0
}

workload_setup_apply "${TREE}" || fail "workload_setup_apply must succeed with stubs"
[[ "${PREFLIGHT_SAW_ROOT}" -eq 1 ]] || fail "units preflight must run"
pass "workload_setup_apply sets ambient WORKLOADS_ROOT for units"

echo "All workload-setup-host offline tests passed."
