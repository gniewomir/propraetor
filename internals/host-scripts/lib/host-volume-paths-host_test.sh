#!/usr/bin/env bash
# Unit tests: Host Volume path vocabulary (mount + owner-tree / Persist locations).
# Seam: host_volume_* helpers (ADR-0054 / #215).
# Repo path internals/ (operator-machine) is distinct from Host Volume mount layout.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=host-volume-paths-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/host-volume-paths-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- defaults match ADR-0054 Host Volume contract ---
unset HV_ROOT || true
[[ "$(host_volume_mount_root)" == "/host-volume" ]] \
  || fail "default mount root wrong: $(host_volume_mount_root)"
[[ "$(host_volume_sot_root)" == "/host-volume" ]] \
  || fail "default SoT root wrong: $(host_volume_sot_root)"
[[ "$(host_volume_host_scripts_root)" == "/host-volume/host-scripts" ]] \
  || fail "default host-scripts root wrong"
[[ "$(host_volume_fabric_root)" == "/host-volume/fabric" ]] \
  || fail "default fabric root wrong"
[[ "$(host_volume_components_sot_root)" == "/host-volume/components" ]] \
  || fail "default components SoT root wrong"
[[ "$(host_volume_component_sot edge)" == "/host-volume/components/edge" ]] \
  || fail "default component SoT wrong"
[[ "$(host_volume_workloads_sot_root)" == "/host-volume/workloads" ]] \
  || fail "default workloads SoT root wrong"
[[ "$(host_volume_workload_sot panel)" == "/host-volume/workloads/panel" ]] \
  || fail "default workload SoT wrong"
[[ "$(host_volume_workload_persist panel)" == "/host-volume/workloads/panel/persist" ]] \
  || fail "default workload Persist wrong"
[[ "$(host_volume_component_persist database)" == "/host-volume/components/database/persist" ]] \
  || fail "default component Persist wrong"
pass "defaults resolve to ADR-0054 Host Volume paths"

# --- HV_ROOT override relocates the whole vocabulary ---
TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/host-volume-paths.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
export HV_ROOT="${TMP}/hv"

[[ "$(host_volume_mount_root)" == "${HV_ROOT}" ]] || fail "HV_ROOT mount"
[[ "$(host_volume_sot_root)" == "${HV_ROOT}" ]] || fail "HV_ROOT SoT"
[[ "$(host_volume_host_scripts_root)" == "${HV_ROOT}/host-scripts" ]] \
  || fail "HV_ROOT host-scripts"
[[ "$(host_volume_component_sot database)" == "${HV_ROOT}/components/database" ]] \
  || fail "HV_ROOT component SoT"
[[ "$(host_volume_workload_persist hello)" == "${HV_ROOT}/workloads/hello/persist" ]] \
  || fail "HV_ROOT workload Persist"
[[ "$(host_volume_component_persist edge)" == "${HV_ROOT}/components/edge/persist" ]] \
  || fail "HV_ROOT component Persist"
pass "HV_ROOT overrides all Host Volume path helpers"

# --- owner args are required (fail closed) ---
if host_volume_component_sot 2>/dev/null; then
  fail "component_sot must require a name"
fi
if host_volume_workload_sot 2>/dev/null; then
  fail "workload_sot must require a basename"
fi
if host_volume_workload_persist 2>/dev/null; then
  fail "workload_persist must require a basename"
fi
if host_volume_component_persist 2>/dev/null; then
  fail "component_persist must require a name"
fi
pass "owner-scoped helpers fail closed without args"

# --- retired helpers must not exist (no dual-layout API) ---
if declare -F host_volume_persist_root >/dev/null 2>&1; then
  fail "host_volume_persist_root must be retired (no top-level data/)"
fi
if declare -F host_volume_fabric_persist >/dev/null 2>&1; then
  fail "host_volume_fabric_persist must be retired (Fabric has no Persist)"
fi
if declare -F host_volume_workloads_persist_root >/dev/null 2>&1; then
  fail "host_volume_workloads_persist_root must be retired"
fi
if declare -F host_volume_components_persist_root >/dev/null 2>&1; then
  fail "host_volume_components_persist_root must be retired"
fi
pass "retired top-level Persist helpers are absent"

# --- module comments keep repo internals/ distinct from Host Volume layout ---
if ! grep -Eq 'operator-machine|repo path|not the (operator|repo)' \
  "${REPO_ROOT}/internals/host-scripts/lib/host-volume-paths-host.sh"; then
  fail "path module must document Host Volume layout vs repo internals/"
fi
if grep -Eq '/var/lib/host-volume|Host Volume SoT segment "internals/"' \
  "${REPO_ROOT}/internals/host-scripts/lib/host-volume-paths-host.sh"; then
  fail "path module must not document retired ADR-0041 Host Volume layout"
fi
pass "module distinguishes Host Volume layout from repo internals/"

echo "All host-volume-paths-host offline tests passed."
