#!/usr/bin/env bash
# Unit tests: Host Volume path vocabulary (mount + owner-tree / Persist locations).
# Seam: host_volume_* helpers. Live behaviour still ADR-0041 paths (#214 prefactor);
# ADR-0054 layout cut switches helper bodies later — not this ticket.
# Repo path internals/ (operator-machine) is distinct from Host Volume mount …/internals/.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=host-volume-paths-host.sh
source "${REPO_ROOT}/internals/host-scripts/lib/host-volume-paths-host.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

# --- defaults match today's live Host Volume contract (ADR-0041) ---
unset HV_ROOT || true
[[ "$(host_volume_mount_root)" == "/var/lib/host-volume" ]] \
  || fail "default mount root wrong: $(host_volume_mount_root)"
[[ "$(host_volume_sot_root)" == "/var/lib/host-volume/internals" ]] \
  || fail "default SoT root wrong: $(host_volume_sot_root)"
[[ "$(host_volume_persist_root)" == "/var/lib/host-volume/data" ]] \
  || fail "default Persist-today root wrong: $(host_volume_persist_root)"
[[ "$(host_volume_host_scripts_root)" == "/var/lib/host-volume/internals/host-scripts" ]] \
  || fail "default host-scripts root wrong"
[[ "$(host_volume_fabric_root)" == "/var/lib/host-volume/internals/fabric" ]] \
  || fail "default fabric root wrong"
[[ "$(host_volume_components_sot_root)" == "/var/lib/host-volume/internals/components" ]] \
  || fail "default components SoT root wrong"
[[ "$(host_volume_component_sot edge)" == "/var/lib/host-volume/internals/components/edge" ]] \
  || fail "default component SoT wrong"
[[ "$(host_volume_workloads_sot_root)" == "/var/lib/host-volume/internals/workloads" ]] \
  || fail "default workloads SoT root wrong"
[[ "$(host_volume_workload_sot panel)" == "/var/lib/host-volume/internals/workloads/panel" ]] \
  || fail "default workload SoT wrong"
[[ "$(host_volume_workload_persist panel)" == "/var/lib/host-volume/data/workloads/panel" ]] \
  || fail "default workload Persist wrong"
[[ "$(host_volume_component_persist database)" == "/var/lib/host-volume/data/components/database" ]] \
  || fail "default component Persist wrong"
[[ "$(host_volume_fabric_persist)" == "/var/lib/host-volume/data/fabric" ]] \
  || fail "default fabric Persist-today wrong"
pass "defaults resolve to ADR-0041 Host Volume paths"

# --- HV_ROOT override relocates the whole vocabulary ---
TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/host-volume-paths.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT
export HV_ROOT="${TMP}/hv"

[[ "$(host_volume_mount_root)" == "${HV_ROOT}" ]] || fail "HV_ROOT mount"
[[ "$(host_volume_sot_root)" == "${HV_ROOT}/internals" ]] || fail "HV_ROOT SoT"
[[ "$(host_volume_persist_root)" == "${HV_ROOT}/data" ]] || fail "HV_ROOT Persist-today"
[[ "$(host_volume_host_scripts_root)" == "${HV_ROOT}/internals/host-scripts" ]] \
  || fail "HV_ROOT host-scripts"
[[ "$(host_volume_component_sot database)" == "${HV_ROOT}/internals/components/database" ]] \
  || fail "HV_ROOT component SoT"
[[ "$(host_volume_workload_persist hello)" == "${HV_ROOT}/data/workloads/hello" ]] \
  || fail "HV_ROOT workload Persist"
[[ "$(host_volume_component_persist edge)" == "${HV_ROOT}/data/components/edge" ]] \
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

# --- module comments keep repo internals/ distinct from Host Volume SoT ---
if ! grep -Eq 'operator-machine|repo path|not the (operator|repo)' \
  "${REPO_ROOT}/internals/host-scripts/lib/host-volume-paths-host.sh"; then
  fail "path module must document Host Volume SoT internals/ vs repo internals/"
fi
pass "module distinguishes Host Volume SoT internals/ from repo internals/"

echo "All host-volume-paths-host offline tests passed."
