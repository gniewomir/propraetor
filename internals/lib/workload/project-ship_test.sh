#!/usr/bin/env bash
# Unit tests: shared Host Workload projection ship inventory (#233).
# Seam: workload_project_stage_ship_inventory.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
# shellcheck source=project-ship.sh
source "${REPO_ROOT}/internals/lib/workload/project-ship.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

TMP="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/wl-proj-ship.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

DEST="${TMP}/dest"
workload_project_stage_ship_inventory "${DEST}" \
  || fail "stage_ship_inventory must succeed"

for f in \
  sync-tree-host.sh \
  workload-materialize-host.sh \
  workload-project-host.sh \
  unit-consumers-host.sh \
  host-volume-paths-host.sh \
  source.sh \
  provides.sh; do
  [[ -f "${DEST}/${f}" ]] || fail "missing projected-tree ship file: ${f}"
done
pass "projection ship inventory stages required libs"

# Mirror and Setup both call the same function (contract grep).
grep -Fq 'workload_project_stage_ship_inventory' \
  "${REPO_ROOT}/internals/ensure-mirror.sh" \
  || fail "Mirror must stage via workload_project_stage_ship_inventory"
grep -Fq 'workload_project_stage_ship_inventory' \
  "${REPO_ROOT}/internals/lib/workload/setup.sh" \
  || fail "Setup stage_payload must stage via workload_project_stage_ship_inventory"
pass "Mirror and Setup share projection ship inventory"

echo "All workload projection ship inventory checks passed."
